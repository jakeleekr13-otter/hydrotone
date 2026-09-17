import AVFoundation

struct VideoMetadata: Sendable {
    enum DynamicRange: String, Sendable { case sdr = "SDR", hlg = "HLG", pq = "HDR10", unknownHDR = "HDR" }
    let codec: String
    let codedSize: CGSize
    let displaySize: CGSize
    let transform: CGAffineTransform
    let duration: Double
    let frameRate: Float
    let bitDepth: Int?
    let primaries: String?
    let transfer: String?
    let matrix: String?
    let dynamicRange: DynamicRange
    let hasDolbyVisionSignaling: Bool
    let audioTrackCount: Int
    var isHDR: Bool { dynamicRange != .sdr }
}
struct MediaInspector {
    func inspect(_ url: URL) async throws -> VideoMetadata {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isReadable), let track = try await asset.loadTracks(withMediaType: .video).first else { throw HydroError.unreadable }
        let (size, transform, rate, formats) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
        guard let format = formats.first else { throw HydroError.unsupported }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, size.width > 0, size.height > 0 else { throw HydroError.unreadable }
        let extensions = (CMFormatDescriptionGetExtensions(format) as NSDictionary?) ?? [:]
        let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction] as? String
        let primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries] as? String
        let matrix = extensions[kCMFormatDescriptionExtension_YCbCrMatrix] as? String
        let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? [String: Any] ?? [:]
        var depth = (extensions[kCMFormatDescriptionExtension_BitsPerComponent] as? NSNumber)?.intValue
        // HEVCDecoderConfigurationRecord contains explicit luma depth; absent metadata stays unknown.
        if depth == nil, let hvcc = atoms["hvcC"] as? Data, hvcc.count > 18 { depth = 8 + Int(hvcc[17] & 7) }
        let subtype = CMFormatDescriptionGetMediaSubType(format)
        let bytes = [UInt8((subtype >> 24) & 255), UInt8((subtype >> 16) & 255), UInt8((subtype >> 8) & 255), UInt8(subtype & 255)]
        let codec = String(bytes: bytes, encoding: .ascii) ?? "Unknown"
        let range: VideoMetadata.DynamicRange
        if transfer == AVVideoTransferFunction_ITU_R_2100_HLG { range = .hlg }
        else if transfer == AVVideoTransferFunction_SMPTE_ST_2084_PQ { range = .pq }
        else if try await track.load(.mediaCharacteristics).contains(.containsHDRVideo) { range = .unknownHDR }
        else { range = .sdr }
        let rect = CGRect(origin: .zero, size: size).applying(transform).standardized
        return VideoMetadata(codec: codec, codedSize: size, displaySize: rect.size, transform: transform,
            duration: duration, frameRate: rate, bitDepth: depth, primaries: primaries, transfer: transfer, matrix: matrix,
            dynamicRange: range, hasDolbyVisionSignaling: atoms["dvcC"] != nil || atoms["dvvC"] != nil || codec == "dvh1" || codec == "dvhe",
            audioTrackCount: try await asset.loadTracks(withMediaType: .audio).count)
    }
}
