import AVFoundation

struct OutputValidator {
    func validate(_ url: URL, source: VideoMetadata, options: ExportOptions, expectedFrames: Int) async throws -> VideoMetadata {
        let result = try await MediaInspector().inspect(url)
        let size = options.size(for: source.displaySize)
        let duration = min(source.duration, options.durationLimit ?? source.duration)
        guard result.codec == "hvc1" || result.codec == "hev1",
              abs(result.displaySize.width - size.width) < 2,
              abs(result.displaySize.height - size.height) < 2,
              abs(result.duration - duration) < max(0.15, 2 / Double(max(1, source.frameRate))),
              result.audioTrackCount == source.audioTrackCount,
              result.transform == .identity else { throw HydroError.invalidOutput }
        if options.range == .sdr {
            guard !result.isHDR, result.transfer == AVVideoTransferFunction_ITU_R_709_2 else { throw HydroError.invalidOutput }
        } else {
            guard result.dynamicRange == source.dynamicRange, result.bitDepth == 10,
                  result.primaries == AVVideoColorPrimaries_ITU_R_2020,
                  result.matrix == AVVideoYCbCrMatrix_ITU_R_2020 else { throw HydroError.invalidOutput }
        }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw HydroError.invalidOutput }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw HydroError.invalidOutput }
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
        guard reader.status == .completed, count == expectedFrames else { throw HydroError.invalidOutput }
        // Decode in the native range: requesting an SDR CGImage here would make a
        // valid PQ export depend on a separate decoder-side tone-map capability.
        let decoder = try AVAssetReader(asset: asset)
        let decoded = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: result.isHDR ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA])
        decoder.add(decoded)
        guard decoder.startReading() else { throw HydroError.invalidOutput }
        defer { decoder.cancelReading() }
        guard let sample = decoded.copyNextSampleBuffer(), CMSampleBufferGetImageBuffer(sample) != nil else { throw HydroError.invalidOutput }
        return result
    }
}
