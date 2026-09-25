import SwiftUI

/// Pro-only batch correction. Every photo gets its own water analysis. One shared look
/// (preset + intensity) applies to all, and a photo may override it.
@MainActor @Observable
final class BatchModel: Identifiable {
    nonisolated static let maxPhotos = 10
    nonisolated static let thumbnailPixels: CGFloat = 400

    struct Look: Equatable, Sendable {
        var preset: DivePreset = .natural
        var intensity: Float = 0.8
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
    }

    let id = UUID()
    let diagnostics: DiagnosticRecorder
    let photos: PhotoProcessor
    var items: [Item]
    var shared = Look()
    var comparing = false
    var saving = false
    var savedCount = 0
    var summary: String?
    var error: String?
    var showPro = false
    var saveTask: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(urls: [URL], diagnostics: DiagnosticRecorder) {
        self.diagnostics = diagnostics
        photos = PhotoProcessor(diagnostics: diagnostics)
        items = urls.map { Item(url: $0) }
    }

    var readyCount: Int { items.filter { $0.analysis != nil }.count }
    func look(for item: Item) -> Look { item.override ?? shared }
    func settings(for item: Item) -> FilterSettings {
        let look = look(for: item)
        return FilterSettings(preset: look.preset, intensity: look.intensity, analysis: item.analysis ?? .neutral)
    }

    /// Analyses one photo at a time, so peak memory does not grow with the selection size.
    func load() async {
        for index in items.indices where items[index].analysis == nil {
            let url = items[index].url
            do {
                let analysis = try await photos.analyze(url)
                let original = try await photos.preview(url, settings: .init(), original: true, maxPixel: Self.thumbnailPixels)
                items[index].analysis = analysis
                items[index].original = original
                items[index].corrected = try await photos.preview(url, settings: settings(for: items[index]),
                                                                  original: false, maxPixel: Self.thumbnailPixels)
                items[index].state = .ready
            } catch is CancellationError { return } catch {
                items[index].state = .failed
                await record(error, operation: .preview)
            }
        }
    }

    /// Re-renders thumbnails that follow the shared look, or only the given photo.
    func refreshThumbnails(only id: Item.ID? = nil) async {
        for index in items.indices where items[index].analysis != nil {
            if let id, items[index].id != id { continue }
            if id == nil, items[index].override != nil { continue }
            do {
                let image = try await photos.preview(items[index].url, settings: settings(for: items[index]),
                                                     original: false, maxPixel: Self.thumbnailPixels)
                try Task.checkCancellation()
                items[index].corrected = image
            } catch is CancellationError { return } catch { await record(error, operation: .preview) }
        }
    }

    func setOverride(_ look: Look?, for id: Item.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].override = look == shared ? nil : look
    }

    func saveAll(purchases: PurchaseStore) {
        guard !saving else { return }
        saving = true
        savedCount = 0
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
                var output: URL?
                do {
                    try StorageCheck.require(bytes: 100_000_000)
                    output = try await photos.export(items[index].url, settings: settings(for: items[index]))
                    try Task.checkCancellation()
                    if let output { try await PhotoLibrarySaver().save(output, kind: .photo) }
                    items[index].state = .saved
                    savedCount += 1
                } catch is CancellationError { TemporaryFiles.remove(output); break } catch {
                    items[index].state = .saveFailed
                    failed += 1
                    await record(error, operation: .save)
                }
                TemporaryFiles.remove(output)
            }
            let total = targets.count
            summary = failed == 0 && savedCount == total
                ? String(localized: "Saved to Photos: \(savedCount)")
                : String(localized: "Saved to Photos: \(savedCount) of \(total)")
        }
    }

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
        if self.error == nil, operation == .save { self.error = failure.message }
    }
}
