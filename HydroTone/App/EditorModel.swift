import SwiftUI
import AVFoundation
import os

@MainActor @Observable
final class EditorModel {
    let media: ImportedMedia
    let photos = PhotoProcessor()
    var settings = FilterSettings()
    var preview: CGImage?
    var originalPreview: CGImage?
    var comparing = false
    var player: AVPlayer?
    var metadata: VideoMetadata?
    var capability = ExportCapability.photo
    let video = VideoExporter()
    let previewSettings = PreviewSettings()
    var options = ExportOptions()
    var showExportOptions = false
    var optionsDismissing = false
    var showPro = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var cancellationNotice = "Export cancelled"
    var completedURL: URL?
    var saving = false
    var loading = true
    var ready = false
    var exporting = false
    var progress: Double = 0
    var error: String?
    var notice: String?
    var exportTask: Task<Void, Never>?
    init(media: ImportedMedia) { self.media = media }
    func load() async {
        defer { loading = false }
        do {
            if media.kind == .photo {
                settings.analysis = try await photos.analyze(media.url)
                originalPreview = try await photos.preview(media.url, settings: settings, original: true)
                await refreshPreview()
            } else {
                let metadata = try await MediaInspector().inspect(media.url)
                self.metadata = metadata
                capability = await ExportCapability.evaluate(url: media.url, metadata: metadata)
                let videoPreview = VideoPreview()
                settings.analysis = try await videoPreview.analyze(media.url, duration: metadata.duration)
                previewSettings.update(settings, comparing: comparing)
                player = AVPlayer(playerItem: try await videoPreview.item(media.url, settings: previewSettings))
            }
            ready = true
        } catch is CancellationError { } catch { report(error) }
    }
    func refreshPreview() async {
        guard media.kind == .photo else {
            previewSettings.update(settings, comparing: comparing)
            if let player, player.rate == 0, let item = player.currentItem {
                item.videoComposition = item.videoComposition?.copy() as? AVVideoComposition
                await player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            return
        }
        do {
            let rendered = try await photos.preview(media.url, settings: settings, original: false)
            try Task.checkCancellation()
            preview = rendered
        } catch is CancellationError { } catch { report(error) }
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
    func startExport(purchases: PurchaseStore, trial: TrialStore) {
        guard !exporting else { return }
        exporting = true
        progress = 0
        player?.pause()
        optionsDismissing = showExportOptions
        showExportOptions = false
        let chosenSettings = settings
        var chosenOptions = options
        cancellationNotice = "Export cancelled"
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
                    output = try await video.export(url: media.url, metadata: metadata, settings: chosenSettings, options: chosenOptions) { [weak self] value in
                        await MainActor.run { self?.progress = value }
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
            notice = "Saved to Photos"
        } catch { report(error) }
    }
    func discardCompleted() { TemporaryFiles.remove(completedURL); completedURL = nil }
    func cancelForBackground() {
        guard exporting else { return }
        cancellationNotice = "Export cancelled because HydroTone went into the background. Keep the app open and try again. Your trial hasn’t been used."
        exportTask?.cancel()
    }
    func report(_ error: Error) {
        #if DEBUG
        Logger(subsystem: "com.hydrotone.app", category: "media").error("\(String(reflecting: error), privacy: .public)")
        #endif
        self.error = (error as? HydroError)?.localizedDescription ?? HydroError.exportFailed.localizedDescription
    }
    func close() { player?.pause(); exportTask?.cancel(); discardCompleted(); TemporaryFiles.remove(media.url) }
}
