import AVFoundation
import CoreImage

final class PreviewSettings: @unchecked Sendable {
    private let lock = NSLock()
    private var value = FilterSettings()
    private var original = false
    func update(_ settings: FilterSettings, comparing: Bool) { lock.lock(); defer { lock.unlock() }; value = settings; original = comparing }
    func snapshot() -> (FilterSettings, Bool) { lock.lock(); defer { lock.unlock() }; return (value, original) }
}
struct VideoPreview {
    let engine = FilterEngine()
    func analyze(_ url: URL, duration: Double) async throws -> WaterAnalysis {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 256)
        var samples: [WaterAnalysis] = []
        for fraction in [0.05, 0.25, 0.5, 0.75, 0.95] {
            try Task.checkCancellation()
            let frame = try await generator.image(at: CMTime(seconds: duration * fraction, preferredTimescale: 600)).image
            samples.append(engine.analyze(CIImage(cgImage: frame)))
        }
        return .median(samples)
    }
    func item(_ url: URL, settings: PreviewSettings) async throws -> AVPlayerItem {
        let asset = AVURLAsset(url: url)
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: { request in
            let (current, original) = settings.snapshot()
            let output = original ? request.sourceImage : engine.apply(request.sourceImage, settings: current)
            request.finish(with: output, context: engine.context)
        })
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        let item = AVPlayerItem(asset: asset)
        item.appliesPerFrameHDRDisplayMetadata = false
        item.videoComposition = composition
        return item
    }
}
