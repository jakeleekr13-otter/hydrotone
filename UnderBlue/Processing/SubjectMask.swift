import CoreImage
import Vision

/// The photo's main subjects (Vision foreground instances, all of them) as a soft mask:
/// 0 is background, 1 is subject. Row 0 is the top row, as in NormalizedDepthMap.
///
/// The local veil measures the broad light around each pixel (RestorationEngine.restore). A bright
/// subject raised that light for the water beside it, so the veil took too much there and the water
/// around the subject turned into a dark band (O4 manta, 1 Oct 2026: band against the water above,
/// lightness -0.032; the source +0.005). With the mask, that light leaves the subject out.
struct SubjectMask: Sendable, Equatable {
    let width: Int
    let height: Int
    let values: [Float]

    /// A larger mask is a reef or a scene, not a subject (m5: the reef block was 31% of the frame).
    static let maximumShare: Float = 0.25
    /// Below this the mask is noise.
    static let minimumShare: Float = 0.005
    /// Vision reads a small image; the mask is made at this long side.
    static let side: CGFloat = 1024

    /// Nil when Vision finds no subject, or the subjects cover too little or too much of the frame.
    static func estimate(_ image: CIImage) -> SubjectMask? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else { return nil }
        let scale = min(1, side / max(extent.width, extent.height))
        let small = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale)))
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: small, options: [:])
        guard (try? handler.perform([request])) != nil, let observation = request.results?.first,
              !observation.allInstances.isEmpty,
              let buffer = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float,
              width > 1, height > 1, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let line = (base + y * row).assumingMemoryBound(to: Float.self)
            for x in 0..<width { values[y * width + x] = line[x].isFinite ? min(1, max(0, line[x])) : 0 }
        }
        let share = values.reduce(0, +) / Float(values.count)
        guard share >= minimumShare, share <= maximumShare else { return nil }
        return SubjectMask(width: width, height: height, values: values)
    }

    /// The mask as an image over `extent` (red holds the mask).
    func image(matching extent: CGRect) -> CIImage {
        let data = values.withUnsafeBytes { Data($0) }
        let mask = CIImage(bitmapData: data, bytesPerRow: width * MemoryLayout<Float>.size,
                           size: CGSize(width: width, height: height), format: .Rf, colorSpace: nil)
        let scaled = mask.transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(width),
                                                            y: extent.height / CGFloat(height)))
        return scaled.transformed(by: CGAffineTransform(translationX: extent.minX - scaled.extent.minX,
                                                        y: extent.minY - scaled.extent.minY))
    }
}
