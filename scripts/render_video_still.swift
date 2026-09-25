import AVFoundation
import CoreImage
import Foundation

@main
struct RenderVideoStill {
    static func main() throws {
        guard (CommandLine.arguments.count == 5 || CommandLine.arguments.count == 6),
              let seconds = Double(CommandLine.arguments[2]) else {
            throw NSError(domain: "RenderVideoStill", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Usage: render-video-still <video> <seconds> <before.jpg> <after.jpg> [natural|tropical|deep]"])
        }

        let videoURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let beforeURL = URL(fileURLWithPath: CommandLine.arguments[3])
        let afterURL = URL(fileURLWithPath: CommandLine.arguments[4])
        let preset: DivePreset
        switch CommandLine.arguments.count == 6 ? CommandLine.arguments[5] : "deep" {
        case "natural": preset = .natural
        case "tropical": preset = .tropical
        case "deep": preset = .deep
        default:
            throw NSError(domain: "RenderVideoStill", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Unknown preset"])
        }
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600),
                                              actualTime: nil)

        let engine = FilterEngine()
        let source = engine.sdr(CIImage(cgImage: frame))
        let analysis = engine.analyze(source)
        let corrected = engine.apply(source, settings: .init(preset: preset, intensity: 1,
                                                              analysis: analysis))
        try engine.context.writeJPEGRepresentation(of: source, to: beforeURL,
                                                    colorSpace: FilterEngine.photoSpace,
                                                    options: [:])
        try engine.context.writeJPEGRepresentation(of: corrected, to: afterURL,
                                                    colorSpace: FilterEngine.photoSpace,
                                                    options: [:])
    }
}
