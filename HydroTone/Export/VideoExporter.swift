import AVFoundation
import CoreImage
import VideoToolbox
import os

struct VideoExportResult: Sendable {
    let url: URL
    let metadata: VideoMetadata
    let frames: Int
    /// Wall time for the whole export and for the frame loop alone. The difference is fixed setup and checking cost.
    let elapsedSeconds: Double
    let frameLoopSeconds: Double
}

actor VideoExporter {
    private let engine = FilterEngine()
    private let restorationEngine = RestorationEngine()
    private let diagnostics: DiagnosticRecorder?
    private let signposter = OSSignposter(subsystem: "com.hydrotone.app", category: "export")
    #if DEBUG
    private let logger = Logger(subsystem: "com.hydrotone.app", category: "video-performance")
    #endif

    init(diagnostics: DiagnosticRecorder? = nil) {
        self.diagnostics = diagnostics
    }

    func export(url: URL, metadata: VideoMetadata, settings: FilterSettings, options: ExportOptions,
                restorationAnalysis: VideoRestorationAnalysis? = nil,
                progress: @escaping @Sendable (Double) async -> Void) async throws -> VideoExportResult {
        let interval = signposter.beginInterval("Video export")
        let startedAt = Date()
        defer { signposter.endInterval("Video export", interval) }
        guard ProcessInfo.processInfo.thermalState != .critical else { throw Failure(kind: .thermal, domain: "HydroTone", code: 0) }
        try Task.checkCancellation()
        let hdr = options.range == .hdr
        guard !hdr || (metadata.isHDR && (metadata.dynamicRange == .hlg || metadata.dynamicRange == .pq) && (metadata.bitDepth ?? 0) >= 10) else { throw HydroError.unsupported }
        let restoration = settings.preset == .original ? nil : restorationAnalysis
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw HydroError.unreadable }
        let duration = min(metadata.duration, options.durationLimit ?? metadata.duration)
        let size = options.size(for: metadata.displaySize)
        let bitrate = Int(min(100_000_000, max(6_000_000, size.width * size.height * Double(max(24, metadata.frameRate)) * 0.12)))
        try StorageCheck.require(bytes: Int64(Double(bitrate) / 8 * duration * 1.3))
        let target = try TemporaryFiles.makeURL(extension: "mov")
        var succeeded = false
        defer { if !succeeded { TemporaryFiles.remove(target) } }
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: target, fileType: .mov)
        defer {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
        }
        let colors = VideoColorPipeline.properties(hdr: hdr, pq: metadata.dynamicRange == .pq)
        let pixelFormat = hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        let toneMappedByComposition = metadata.isHDR && !hdr
        let output: AVAssetReaderOutput
        if toneMappedByComposition {
            // Apple's compositor can tone-map PQ sources that direct decoder pixel transfer rejects.
            // It also matches the editor's SDR preview and retains variable source timing.
            var composition = try await AVVideoComposition.Configuration(for: asset)
            composition.sourceTrackIDForFrameTiming = track.trackID
            composition.colorPrimaries = colors[AVVideoColorPrimariesKey] as? String
            composition.colorTransferFunction = colors[AVVideoTransferFunctionKey] as? String
            composition.colorYCbCrMatrix = colors[AVVideoYCbCrMatrixKey] as? String
            let composed = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
            composed.videoComposition = AVVideoComposition(configuration: composition)
            output = composed
        } else {
            var decoderSettings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            if !hdr { decoderSettings[AVVideoColorPropertiesKey] = colors }
            output = AVAssetReaderTrackOutput(track: track, outputSettings: decoderSettings)
        }
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw HydroError.unsupported }
        reader.add(output)
        let videoSettings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height), AVVideoColorPropertiesKey: colors,
            AVVideoCompressionPropertiesKey: VideoColorPipeline.compression(hdr: hdr, bitrate: bitrate, frameRate: metadata.frameRate)]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else { throw HydroError.unsupported }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw HydroError.unsupported }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true])
        // Keep every audio track, retaining original compressed samples and their timestamps.
        var audio: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for audioTrack in try await asset.loadTracks(withMediaType: .audio) {
            let format = try await audioTrack.load(.formatDescriptions).first
            let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            audioOutput.alwaysCopiesSampleData = false
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            guard reader.canAdd(audioOutput), writer.canAdd(audioInput) else { throw HydroError.unsupported }
            reader.add(audioOutput); writer.add(audioInput)
            audio.append((audioOutput, audioInput))
        }
        let end = CMTime(seconds: duration, preferredTimescale: 60000)
        reader.timeRange = CMTimeRange(start: .zero, end: end)
        guard writer.startWriting() else { throw writer.error ?? HydroError.exportFailed }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { throw reader.error ?? HydroError.unreadable }
        let loopStartedAt = Date()
        var videoDone = false
        var audioDone = Set<Int>()
        var frames = 0
        var recordedRenderFallback = false
        var lastProgress = -1.0
        var lastActivity = Date()
        while !videoDone || audioDone.count < audio.count {
            try Task.checkCancellation()
            if frames % 30 == 0, ProcessInfo.processInfo.thermalState == .critical { throw Failure(kind: .thermal, domain: "HydroTone", code: 0) }
            guard writer.status == .writing, reader.status != .failed else { throw writer.error ?? reader.error ?? HydroError.exportFailed }
            var advanced = false
            var destination: CVPixelBuffer?
            if !videoDone && input.isReadyForMoreMediaData {
                guard let pool = adaptor.pixelBufferPool else { throw HydroError.exportFailed }
                let allocation = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
                    [kCVPixelBufferPoolAllocationThresholdKey: 6] as CFDictionary, &destination)
                guard allocation == kCVReturnSuccess || allocation == kCVReturnWouldExceedAllocationThreshold else { throw HydroError.exportFailed }
            }
            if !videoDone && input.isReadyForMoreMediaData, let destination {
                let frame: (CIImage, CMTime)? = try autoreleasepool {
                    guard let sample = output.copyNextSampleBuffer() else { videoDone = true; input.markAsFinished(); return nil }
                    guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw HydroError.unreadable }
                    let time = CMSampleBufferGetPresentationTimeStamp(sample)
                    guard time < end else { videoDone = true; input.markAsFinished(); return nil }
                    let source = CIImage(cvPixelBuffer: buffer).transformed(by: toneMappedByComposition ? .identity : metadata.transform)
                    let oriented = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
                    let scaled = oriented.transformed(by: CGAffineTransform(scaleX: size.width / oriented.extent.width, y: size.height / oriented.extent.height))
                    return (scaled, time)
                }
                if let frame {
                    VideoColorPipeline.tag(destination, hdr: hdr, pq: metadata.dynamicRange == .pq)
                    let fallback = engine.apply(frame.0, settings: settings)
                    let corrected: CIImage
                    if let plan = restoration?.exportPlan(at: frame.1.seconds, preservesHDR: hdr) {
                        do {
                            corrected = try restorationEngine.combined(frame.0, plan: plan,
                                                                        settings: settings, filter: engine)
                        } catch {
                            corrected = fallback
                            if !recordedRenderFallback, let diagnostics {
                                recordedRenderFallback = true
                                await diagnostics.record(.restorationFallback(.videoRender),
                                                         operation: .videoRestoration)
                            }
                        }
                    } else { corrected = fallback }
                    engine.context.render(corrected, to: destination, bounds: CGRect(origin: .zero, size: size),
                                          colorSpace: VideoColorPipeline.colorSpace(hdr: hdr, pq: metadata.dynamicRange == .pq))
                    guard adaptor.append(destination, withPresentationTime: frame.1) else { throw writer.error ?? HydroError.exportFailed }
                    frames += 1
                    if frames.isMultiple(of: 300) { engine.context.clearCaches() }
                }
                advanced = true
                if let pts = frame?.1.seconds {
                    let fraction = min(0.99, max(0, pts / duration))
                    if fraction - lastProgress >= 0.01 { lastProgress = fraction; await progress(fraction) }
                }
            }
            for (index, pair) in audio.enumerated() where !audioDone.contains(index) && pair.1.isReadyForMoreMediaData {
                try autoreleasepool {
                    if let sample = pair.0.copyNextSampleBuffer() {
                        if CMSampleBufferGetNumSamples(sample) > 0 {
                            guard pair.1.append(sample) else { throw writer.error ?? HydroError.exportFailed }
                        }
                    } else { pair.1.markAsFinished(); audioDone.insert(index) }
                }
                advanced = true
            }
            if advanced { lastActivity = Date() }
            else {
                guard Date().timeIntervalSince(lastActivity) < 30 else { throw HydroError.exportFailed }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        let frameLoopSeconds = Date().timeIntervalSince(loopStartedAt)
        try Task.checkCancellation()
        guard frames > 0, reader.status != .failed else { throw reader.error ?? HydroError.unreadable }
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else { throw writer.error ?? HydroError.exportFailed }
        let result = try await OutputValidator().validate(target, source: metadata, options: options, expectedFrames: frames)
        await progress(1)
        #if DEBUG
        let elapsed = max(0.001, Date().timeIntervalSince(startedAt))
        logger.debug("frames=\(frames) seconds=\(elapsed) exportFPS=\(Double(frames) / elapsed) millisecondsPerFrame=\(elapsed * 1000 / Double(max(1, frames)))")
        #endif
        succeeded = true
        return VideoExportResult(url: target, metadata: result, frames: frames,
                                 elapsedSeconds: Date().timeIntervalSince(startedAt), frameLoopSeconds: frameLoopSeconds)
    }

    /// Exports a short probe with the real pipeline and scales its frame-loop time to the full length.
    func estimateSeconds(url: URL, metadata: VideoMetadata, settings: FilterSettings, options: ExportOptions,
                         restorationAnalysis: VideoRestorationAnalysis?) async throws -> Double {
        let length = min(metadata.duration, options.durationLimit ?? metadata.duration)
        var probe = options
        probe.durationLimit = min(1, length)
        let result = try await export(url: url, metadata: metadata, settings: settings, options: probe,
                                      restorationAnalysis: restorationAnalysis) { _ in }
        TemporaryFiles.remove(result.url)
        let setup = max(0, result.elapsedSeconds - result.frameLoopSeconds)
        return setup + result.frameLoopSeconds * length / min(1, length)
    }
}
