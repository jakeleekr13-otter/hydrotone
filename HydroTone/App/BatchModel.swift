import SwiftUI

/// Pro-only batch correction. Every photo gets its own water analysis. One shared look
/// (preset + intensity) applies to all, and a photo may override it. Custom uses the one saved
/// set of CustomAdjustments for every photo.
@MainActor @Observable
final class BatchModel: Identifiable {
    nonisolated static let maxPhotos = 10
    nonisolated static let thumbnailPixels: CGFloat = 400

    struct Look: Equatable, Sendable {
        var preset: DivePreset = .natural
        var intensity: Float = 0.8
        /// Custom renders at full strength, so two Custom looks match whatever their intensity.
        static func == (a: Self, b: Self) -> Bool { a.preset == b.preset && (a.preset == .custom || a.intensity == b.intensity) }
    }
    enum State: Equatable { case loading, ready, failed, saved, saveFailed }
    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        var analysis: WaterAnalysis?
        var original: CGImage?
        var corrected: CGImage?
        var override: Look?
        var state = State.loading
        /// The last thumbnail render failed, so `corrected` no longer matches the look that will be saved.
        var previewFailed = false
    }

    let id = UUID()
    let diagnostics: DiagnosticRecorder
    let photos: PhotoProcessor
    var items: [Item]
    var shared = Look()
    private let adjustmentStore: CustomAdjustmentsStore
    /// The saved Custom sliders, shared with the editor. Written back on every change.
    var adjustments: CustomAdjustments { didSet { if adjustments != oldValue { adjustmentStore.save(adjustments) } } }
    var comparing = false
    var saving = false
    var savedCount = 0
    var summary: String?
    var error: String?
    var showPro = false
    var saveTask: Task<Void, Never>?
    private var interruption: String?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(urls: [URL], diagnostics: DiagnosticRecorder, adjustmentStore: CustomAdjustmentsStore = .init()) {
        self.diagnostics = diagnostics
        self.adjustmentStore = adjustmentStore
        adjustments = adjustmentStore.load()
        photos = PhotoProcessor(diagnostics: diagnostics)
        items = urls.map { Item(url: $0) }
    }

    /// Photos that can still be saved. Saved photos drop out, so a second Save All has nothing stale to report.
    var pendingCount: Int { items.filter { $0.analysis != nil && $0.state != .saved }.count }
    /// Fixed when a save starts, so progress does not shrink as photos finish.
    private(set) var saveTotal = 0
    func look(for item: Item) -> Look { item.override ?? shared }
    func settings(for item: Item) -> FilterSettings {
        let look = look(for: item)
        return FilterSettings(preset: look.preset, intensity: look.intensity, analysis: item.analysis ?? .neutral,
                              adjustments: look.preset == .custom ? adjustments : .zero)
    }

    /// Analyses one photo at a time, so peak memory does not grow with the selection size.
    func load() async {
        for index in items.indices where items[index].analysis == nil {
            let url = items[index].url
            do {
                let analysis = try await photos.analyze(url)
                items[index].analysis = analysis
            } catch is CancellationError { return } catch {
                items[index].state = .failed
                await record(error, operation: .inspection)
                continue
            }
            do {
                items[index].original = try await photos.preview(url, settings: .init(), original: true, maxPixel: Self.thumbnailPixels)
                items[index].corrected = try await photos.preview(url, settings: settings(for: items[index]),
                                                                  original: false, maxPixel: Self.thumbnailPixels)
            } catch is CancellationError { return } catch {
                // Analysis succeeded, so the photo can still be saved; only its thumbnail is missing.
                items[index].previewFailed = true
                await record(error, operation: .preview)
            }
            items[index].state = .ready
        }
    }

    /// Re-renders thumbnails that follow the shared look or use Custom (the sliders are shared), or only the given photo.
    func refreshThumbnails(only id: Item.ID? = nil) async {
        for index in items.indices where items[index].analysis != nil {
            if let id, items[index].id != id { continue }
            if id == nil, let override = items[index].override, override.preset != .custom { continue }
            do {
                let image = try await photos.preview(items[index].url, settings: settings(for: items[index]),
                                                     original: false, maxPixel: Self.thumbnailPixels)
                try Task.checkCancellation()
                items[index].corrected = image
                items[index].previewFailed = false
            } catch is CancellationError { return } catch {
                // Never keep showing the previous look: Save All would export a different one.
                items[index].corrected = nil
                items[index].previewFailed = true
                await record(error, operation: .preview)
            }
        }
    }

    func setOverride(_ look: Look?, for id: Item.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].override = look == shared ? nil : look
    }

    func saveAll(purchases: PurchaseStore) {
        guard !saving else { return }
        guard pendingCount > 0 else { return }
        saving = true
        savedCount = 0
        saveTotal = pendingCount
        interruption = nil
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish batch save") { [weak self] in
            Task { @MainActor in self?.saveTask?.cancel() }
        }
        saveTask = Task {
            defer {
                saving = false; saveTask = nil
                if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
            }
            await purchases.refreshEntitlement()
            guard purchases.isPro else { showPro = true; return }
            let targets = items.indices.filter { items[$0].analysis != nil && items[$0].state != .saved }
            var failed = 0
            for index in targets {
                if Task.isCancelled { break }
                let output: URL
                do {
                    try StorageCheck.require(bytes: 100_000_000)
                    output = try await photos.export(items[index].url, settings: settings(for: items[index]))
                } catch is CancellationError { break } catch {
                    items[index].state = .saveFailed; failed += 1
                    await record(error, operation: .export)
                    continue
                }
                defer { TemporaryFiles.remove(output) }
                do {
                    try Task.checkCancellation()
                    try await PhotoLibrarySaver().save(output, kind: .photo)
                    items[index].state = .saved
                    savedCount += 1
                } catch is CancellationError { break } catch {
                    items[index].state = .saveFailed; failed += 1
                    await record(error, operation: .save)
                }
            }
            // Count every selected photo, including ones that never opened, so partial success never reads as full.
            let total = items.count
            let unopened = items.filter { $0.state == .failed }.count
            var parts = [savedCount == total && failed == 0
                ? String(localized: "Saved to Photos: \(savedCount)")
                : String(localized: "Saved to Photos: \(savedCount) of \(total)")]
            if unopened > 0 { parts.append(String(localized: "Couldn’t open: \(unopened)")) }
            if let interruption { parts.append(interruption) }
            summary = parts.joined(separator: "\n")
        }
    }

    func memoryWarning() {
        let failure = Failure(kind: .memoryPressure, domain: "HydroTone", code: 0)
        Task { await diagnostics.record(failure, operation: .export) }
        if saving { interruption = failure.message; saveTask?.cancel() }
    }

    func recordPreviewFailure(_ error: Error) async { await record(error, operation: .preview) }

    func close() {
        saveTask?.cancel()
        for item in items {
            TemporaryFiles.remove(item.url)
            let url = item.url, photos = photos
            Task { await photos.forget(url) }
        }
    }

    private func record(_ error: Error, operation: Operation) async {
        let failure = Failure.classify(error, operation: operation)
        guard failure.kind != .cancelled else { return }
        await diagnostics.record(failure, operation: operation)
        if self.error == nil, operation == .save || operation == .export { self.error = failure.message }
    }
}
