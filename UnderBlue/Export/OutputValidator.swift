import AVFoundation
import os

struct OutputValidator {
    #if DEBUG
    private static let logger = Logger(subsystem: "com.underblue.app", category: "output-validator")
    #endif

    /// The error for a failed check. DEBUG builds log which check failed and its values.
    private func rejected(_ check: String) -> HydroError {
        #if DEBUG
        Self.logger.error("export rejected: \(check, privacy: .public)")
        #endif
        return .invalidOutput
    }

    func validate(_ url: URL, source: VideoMetadata, options: ExportOptions, expectedFrames: Int) async throws -> VideoMetadata {
        let result = try await MediaInspector().inspect(url)
        let size = options.size(for: source.displaySize)
        let duration = min(source.duration, options.durationLimit ?? source.duration)
        guard result.codec == "hvc1" || result.codec == "hev1" else { throw rejected("codec \(result.codec)") }
        guard abs(result.displaySize.width - size.width) < 2, abs(result.displaySize.height - size.height) < 2 else {
            throw rejected("size \(result.displaySize) vs \(size)")
        }
        let durationLimit = max(0.15, 2 / Double(max(1, source.frameRate)))
        guard abs(result.duration - duration) < durationLimit else {
            throw rejected("duration \(result.duration) vs \(duration), limit \(durationLimit)")
        }
        guard result.audioTrackCount == source.audioTrackCount else {
            throw rejected("audio tracks \(result.audioTrackCount) vs \(source.audioTrackCount)")
        }
        guard result.transform == .identity else { throw rejected("transform \(result.transform)") }
        if options.range == .sdr {
            guard !result.isHDR, result.transfer == AVVideoTransferFunction_ITU_R_709_2 else {
                throw rejected("SDR output isHDR \(result.isHDR) transfer \(String(describing: result.transfer))")
            }
        } else {
            guard result.dynamicRange == source.dynamicRange, result.bitDepth == 10,
                  result.primaries == AVVideoColorPrimaries_ITU_R_2020,
                  result.matrix == AVVideoYCbCrMatrix_ITU_R_2020 else {
                throw rejected("HDR output range \(result.dynamicRange) bits \(String(describing: result.bitDepth)) primaries \(String(describing: result.primaries)) matrix \(String(describing: result.matrix))")
            }
        }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw rejected("no video track") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw rejected("read-back did not start: \(String(describing: reader.error))") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var count = 0
        while true {
            try Task.checkCancellation()
            let hasFrame: Bool = autoreleasepool {
                guard let sample = output.copyNextSampleBuffer() else { return false }
                count += CMSampleBufferGetNumSamples(sample)
                return true
            }
            if !hasFrame { break }
        }
        guard reader.status == .completed, count == expectedFrames else {
            throw rejected("frames read back \(count) vs written \(expectedFrames), reader status \(reader.status.rawValue)")
        }
        // Decode in the native range: requesting an SDR CGImage here would make a
        // valid PQ export depend on a separate decoder-side tone-map capability.
        let decoder = try AVAssetReader(asset: asset)
        let decoded = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: result.isHDR ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA])
        decoder.add(decoded)
        guard decoder.startReading() else { throw rejected("decode did not start: \(String(describing: decoder.error))") }
        defer { decoder.cancelReading() }
        guard let sample = decoded.copyNextSampleBuffer(), CMSampleBufferGetImageBuffer(sample) != nil else {
            throw rejected("first frame did not decode")
        }
        return result
    }
}
