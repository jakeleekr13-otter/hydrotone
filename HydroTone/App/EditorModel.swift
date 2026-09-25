import SwiftUI
import AVFoundation

@MainActor @Observable
final class EditorModel {
    let diagnostics: DiagnosticRecorder
    let media: ImportedMedia
    let photos: PhotoProcessor
    private let adjustmentStore: CustomAdjustmentsStore
    /// The saved Custom sliders are written back on every change.
    var settings = FilterSettings() {
        didSet { if settings.adjustments != oldValue.adjustments { adjustmentStore.save(settings.adjustments) } }
    }
    var preview: CGImage?
    var originalPreview: CGImage?
    /// Long side of the photo preview. It doubles once the user zooms in, so fine detail stays sharp.
    private(set) var previewMaxPixel: CGFloat = 1600
    private var detailPreviewBlocked = false
    var comparing = false
    var player: AVPlayer?
    var clipPlaying = false
    private var clipStart: CMTime?
    private var clipObserver: Any?
    static let clipSeconds = 3.0
    var metadata: VideoMetadata?
    var videoAnalysis: VideoRestorationAnalysis?
    var capability = ExportCapability.photo
    let video: VideoExporter
    let videoPreview: VideoPreview
    let previewSettings = PreviewSettings()
    var options = ExportOptions()
    var showExportOptions = false
    var estimates: [ExportOptions.Resolution: Double] = [:]
    var estimating = false
    private var estimateTask: Task<Void, Never>?
    private let estimator = VideoExporter()
    var optionsDismissing = false
    var showPro = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var cancellationNotice = String(localized: "Export cancelled")
    var completedURL: URL?
    var saving = false
    var loading = true
    /// True while scene analysis (depth + water model) runs. Export waits for it, so the file matches the preview.
    var analyzing = false
    var ready = false
    var previewPaused = false
    private var previewFailures = 0
    private var previewGeneration = PreviewGeneration()
    var exporting = false
    var progress: Double = 0
    var error: String?
    var notice: String?
    var exportTask: Task<Void, Never>?
    init(media: ImportedMedia, diagnostics: DiagnosticRecorder, adjustmentStore: CustomAdjustmentsStore = .init()) {
        self.media = media
        self.diagnostics = diagnostics
        self.adjustmentStore = adjustmentStore
        photos = PhotoProcessor(diagnostics: diagnostics)
        video = VideoExporter(diagnostics: diagnostics)
        videoPreview = VideoPreview(diagnostics: diagnostics)
        settings.adjustments = adjustmentStore.load()
    }
    func load() async {
        defer { loading = false; analyzing = false }
        do {
            if media.kind == .photo {
                analyzing = true
                settings.analysis = try await photos.analyze(media.url)
                analyzing = false
                originalPreview = try await photos.preview(media.url, settings: settings, original: true)
                await refreshPreview()
            } else {
                let metadata = try await SafeReadRetry().run(operation: .inspection) { try await MediaInspector().inspect(media.url) }
                self.metadata = metadata
                previewSettings.update(settings, comparing: comparing)
                player = AVPlayer(playerItem: try await videoPreview.item(media.url, settings: previewSettings))
                ready = true
                // Show the existing HydroTone preview immediately. Device benchmarking and
                // depth analysis may continue without keeping the editor behind "Opening…".
                loading = false
                analyzing = true
                capability = await ExportCapability.evaluate(url: media.url, metadata: metadata)
                // The video is already open and playing here. A failed scene analysis only loses the
                // scene correction, so record it as a restoration fallback, not as "couldn't open".
                let analysis: VideoRestorationAnalysis
                do {
                    analysis = try await videoPreview.analyze(media.url, metadata: metadata)
                } catch is CancellationError { return } catch {
                    let fallback = Failure.restorationFallback(.videoSceneAnalysis)
                    Task { await diagnostics.record(fallback, operation: .videoRestoration) }
                    if notice == nil { notice = fallback.message }
                    return
                }
                videoAnalysis = analysis
                settings.analysis = analysis.legacyAnalysis
                previewSettings.update(settings, comparing: comparing)
                if let item = player?.currentItem {
                    let generation = previewGeneration.begin()
                    do {
                        let composition = try await videoPreview.composition(asset: item.asset,
                                                                             settings: previewSettings,
                                                                             analysis: analysis)
                        if previewGeneration.accepts(generation) { item.videoComposition = composition }
                    } catch is CancellationError { return } catch { report(error, operation: .preview) }
                }
            }
            ready = media.kind == .photo ? preview != nil : player != nil
        } catch is CancellationError { } catch { report(error, operation: .inspection) }
    }
    func refreshPreview() async {
        guard !previewPaused else { return }
        guard media.kind == .photo else {
            previewSettings.update(settings, comparing: comparing)
            let generation = previewGeneration.begin()
            guard let player, let item = player.currentItem, let videoAnalysis else { return }
            do {
                let composition = try await videoPreview.composition(asset: item.asset, settings: previewSettings,
                                                                     analysis: videoAnalysis)
                try Task.checkCancellation()
                guard previewGeneration.accepts(generation) else { return }
                item.videoComposition = composition
                if player.rate == 0 {
                    await player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
                }
                previewFailures = 0
            } catch is CancellationError { } catch {
                previewFailures += 1
                if previewFailures >= 3 { previewPaused = true }
                report(error, operation: .preview)
            }
            return
        }
        do {
            let rendered = try await photos.preview(media.url, settings: settings, original: false, maxPixel: previewMaxPixel)
            try Task.checkCancellation()
            preview = rendered
            previewFailures = 0
        } catch is CancellationError { } catch {
            previewFailures += 1
            if previewFailures >= 3 { previewPaused = true }
            report(error, operation: .preview)
        }
    }
    /// Plays a short segment from the current position, then returns to its start
    /// so presets and Compare can be judged on the same frames.
    func playClip() async {
        guard let player, let metadata, !exporting else { return }
        stopClip(rewind: false)
        var start = player.currentTime().seconds
        if !start.isFinite || start + Self.clipSeconds > metadata.duration { start = max(0, metadata.duration - Self.clipSeconds) }
        let startTime = CMTime(seconds: start, preferredTimescale: 600)
        let endTime = CMTime(seconds: min(metadata.duration, start + Self.clipSeconds), preferredTimescale: 600)
        await player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
        clipStart = startTime
        clipObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: endTime)], queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.stopClip(rewind: true) }
        }
        clipPlaying = true
        player.play()
    }
    func stopClip(rewind: Bool) {
        guard let player else { return }
        if let clipObserver { player.removeTimeObserver(clipObserver) }
        clipObserver = nil
        guard clipPlaying else { return }
        clipPlaying = false
        player.pause()
        if rewind, let clipStart { player.seek(to: clipStart, toleranceBefore: .zero, toleranceAfter: .zero) }
        clipStart = nil
    }
    func requestExport(purchases: PurchaseStore, trial: TrialStore) async {
        await purchases.refreshEntitlement()
        if !purchases.isPro {
            guard trial.available else { report(HydroError.trialUnavailable); return }
            guard trial.canExport(media.kind) else { showPro = true; return }
            options.range = .sdr
            options.resolution = .hd
            options.durationLimit = TrialStore.videoSeconds
        } else { options.durationLimit = nil }
        showExportOptions = true
    }
    /// Measures each resolution on this device with the current preset and color range.
    func estimateExportTimes() {
        estimateTask?.cancel()
        estimates = [:]
        guard let metadata, !exporting else { return }
        let url = media.url, settings = settings, analysis = videoAnalysis, base = options
        estimating = true
        estimateTask = Task {
            defer { if !Task.isCancelled { estimating = false } }
            var measured: [String: Double] = [:]
            for resolution in ExportOptions.Resolution.allCases {
                var options = base
                options.resolution = resolution
                let size = options.size(for: metadata.displaySize)
                let key = "\(size.width)x\(size.height)"
                do {
                    let seconds: Double
                    if let known = measured[key] { seconds = known } else {
                        seconds = try await estimator.estimateSeconds(url: url, metadata: metadata, settings: settings,
                                                                      options: options, restorationAnalysis: analysis)
                    }
                    try Task.checkCancellation()
                    measured[key] = seconds
                    estimates[resolution] = seconds
                } catch { return }
            }
        }
    }
    func cancelEstimates() { estimateTask?.cancel(); estimateTask = nil; estimating = false }
    func startExport(purchases: PurchaseStore, trial: TrialStore) {
        guard !exporting else { return }
        cancelEstimates()
        exporting = true
        progress = 0
        stopClip(rewind: false)
        player?.pause()
        optionsDismissing = showExportOptions
        showExportOptions = false
        let chosenSettings = settings
        var chosenOptions = options
        cancellationNotice = String(localized: "Export cancelled")
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish or cancel export") { [weak self] in
            Task { @MainActor in self?.cancelForBackground() }
        }
        exportTask = Task {
            var reserved = false
            defer {
                exporting = false; exportTask = nil
                if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
            }
            do {
                await purchases.refreshEntitlement()
                try Task.checkCancellation()
                if !purchases.isPro {
                    guard trial.canExport(media.kind) else { showPro = true; return }
                    try trial.reserve(media.kind); reserved = true
                    chosenOptions.resolution = .hd
                    chosenOptions.range = .sdr
                    chosenOptions.durationLimit = TrialStore.videoSeconds
                } else { chosenOptions.durationLimit = nil }
                let output: URL
                if let metadata {
                    output = try await video.export(url: media.url, metadata: metadata, settings: chosenSettings,
                                                    options: chosenOptions, restorationAnalysis: videoAnalysis) { value in
                        await self.updateProgress(value)
                    }.url
                } else {
                    try StorageCheck.require(bytes: 100_000_000)
                    output = try await photos.export(media.url, settings: chosenSettings)
                }
                do {
                    try Task.checkCancellation()
                    if reserved { try trial.commit(media.kind); reserved = false }
                    completedURL = output
                } catch { TemporaryFiles.remove(output); throw error }
            } catch is CancellationError { notice = cancellationNotice }
            catch { report(error) }
            if reserved {
                do { try trial.rollback() } catch { report(error) }
            }
        }
    }
    func saveCompleted() async {
        guard let completedURL, !saving else { return }
        saving = true
        defer { saving = false }
        do {
            try await PhotoLibrarySaver().save(completedURL, kind: media.kind)
            TemporaryFiles.remove(completedURL)
            self.completedURL = nil
            notice = String(localized: "Saved to Photos")
        } catch { report(error, operation: .save) }
    }
    func discardCompleted() { TemporaryFiles.remove(completedURL); completedURL = nil }
    func cancelForBackground() {
        guard exporting else { return }
        cancellationNotice = String(localized: "Export cancelled because HydroTone went into the background. Keep the app open and try again. Your trial hasn’t been used.")
        exportTask?.cancel()
    }
    private func updateProgress(_ value: Double) { progress = value }
    func retryPreview() async {
        previewPaused = false; previewFailures = 0
        await refreshPreview()
    }
    /// Called when the photo preview is zoomed in: re-render both previews at twice the size, once.
    func requestDetailPreview() {
        guard media.kind == .photo, previewMaxPixel < 3200, !loading, !detailPreviewBlocked else { return }
        previewMaxPixel = 3200
        Task {
            do {
                originalPreview = try await photos.preview(media.url, settings: settings, original: true, maxPixel: previewMaxPixel)
            } catch is CancellationError { } catch { report(error, operation: .preview) }
            await refreshPreview()
        }
    }
    func memoryWarning() {
        let failure = Failure(kind: .memoryPressure, domain: "HydroTone", code: 0)
        Task { await diagnostics.record(failure, operation: .export) }
        // Later previews go back to the standard size, for the rest of this edit; the current ones stay on screen.
        previewMaxPixel = 1600
        detailPreviewBlocked = true
        if exporting { cancellationNotice = failure.message; exportTask?.cancel() }
    }
    func playbackFailed(_ notification: Notification) {
        guard let item = notification.object as? AVPlayerItem, item === player?.currentItem else { return }
        previewPaused = true
        let playbackError = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            ?? item.error ?? HydroError.unreadable
        report(playbackError, operation: .preview)
    }
    func report(_ error: Error, operation: Operation = .export) {
        let failure = Failure.classify(error, operation: operation)
        guard failure.kind != .cancelled else { return }
        Task { await diagnostics.record(failure, operation: operation) }
        // Keep one actionable alert visible instead of presenting a stream of duplicates.
        if self.error == nil { self.error = failure.message }
    }
    func close() { cancelEstimates(); stopClip(rewind: false); player?.pause(); exportTask?.cancel(); discardCompleted(); TemporaryFiles.remove(media.url) }
}
