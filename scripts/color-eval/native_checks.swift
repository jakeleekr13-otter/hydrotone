import CoreImage
import Foundation
import simd

@main
struct NativeChecks {
    static func main() {
        let engine = FilterEngine()
        precondition(engine.finishingKernelAvailable, "Metal finishing kernel failed to compile")
        var cases = 0
        func check(_ condition: Bool, _ message: String) {
            if !condition { print("FAIL: \(message)"); exit(1) }
            cases += 1
        }
        let colors: [SIMD3<Float>] = [.zero, .init(repeating: 0.001), .init(repeating: 0.2),
            .init(0.02, 0.2, 0.6), .init(0.24, 0.4, 0.45), .init(0.3, 0.2, 0.4),
            .init(0.2, 0.5, 0.1), .init(0.8, 0.9, 1), .init(1.5, 2, 2.2)]
        for c in colors {
            check(simd_length(FinishingMath.working(FinishingMath.display(c)) - c) < 0.00002,
                  "Working/display primary conversions do not round-trip")
        }
        for strength: Float in [0, 0.3, 1] {
            var v = ColorCorrection.identity
            v.castGains = .init(1.2, 0.98, 0.98)
            v.waterLit = .init(0.1, 0.2, 0.6)
            v.waterRedness = 0.16; v.waterChroma = 0.8
            v.subjectTone = .init(1, 0.8, 0.6)
            v.neutralGains = .init(1.1, 0.98, 1)
            v.referenceGains = .init(4, 0.6, 0.5); v.referenceStrength = strength
            // At full strength the CPU colour stage owns contrast/offset. At fractional
            // strengths leave controls at identity to isolate GPU/CPU colour blending.
            if strength == 1 { v.brightness = -0.08; v.contrast = 1.04 }
            for c in colors {
                let image = CIImage(color: CIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z),
                    colorSpace: FilterEngine.workingSpace)!).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
                var pixel = [Float](repeating: 0, count: 4)
                engine.context.render(engine.finishing(image, correction: v), toBitmap: &pixel, rowBytes: 16,
                    bounds: CGRect(x: 8, y: 8, width: 1, height: 1), format: .RGBAf, colorSpace: FilterEngine.workingSpace)
                let expected = FinishingMath.shoulder(FinishingMath.color(c, correction: v), reference: c)
                let error = abs(SIMD3(pixel[0], pixel[1], pixel[2]) - expected).max()
                check(error < 0.006 * max(1, expected.max()), "CPU/Metal mismatch: strength=\(strength), input=\(c), error=\(error)")
                check(pixel.allSatisfy(\.isFinite), "Nonfinite rendered output")
            }
        }
        var scene = WaterAnalysis(redLoss: 0.62, contrast: 0.35, saturation: 0.67,
            meanRed: 0.16, meanGreen: 0.34, meanBlue: 0.52, midLuminance: 0.29,
            waterRed: 0.10, waterGreen: 0.22, waterBlue: 0.62,
            neutralRed: 0.28, neutralGreen: 0.59, neutralBlue: 0.67, neutralShare: 0.20, highShare: 0.38)
        let active = ColorCorrection.make(analysis: scene, preset: .natural)
        check(active.referenceStrength > 0.9, "Broad bright neutral evidence should enable adaptation")
        check(active.referenceGains.x > active.referenceGains.y, "Cool cast should restore measured red differences")
        check(ColorCorrection.make(analysis: scene, preset: .original) == .identity, "Original must remain untouched")
        scene.neutralShare = 0
        check(ColorCorrection.make(analysis: scene, preset: .natural).referenceStrength == 0, "No evidence must disable adaptation")
        scene.neutralShare = 0.20; scene.midLuminance = 0.08
        check(ColorCorrection.make(analysis: scene, preset: .natural).referenceStrength == 0, "Dark scene must retain established correction")
        check(ColorCorrection.make(analysis: .neutral, preset: .natural).referenceStrength == 0, "Neutral scene must remain neutral")
        // With reliable gains, neighbouring coloured subjects must retain separate red levels.
        var v = ColorCorrection.identity
        v.referenceStrength = 1; v.referenceGains = .init(4, 0.6, 0.5)
        let a = FinishingMath.display(FinishingMath.color(FinishingMath.working(.init(0.08, 0.3, 0.4)), correction: v))
        let b = FinishingMath.display(FinishingMath.color(FinishingMath.working(.init(0.16, 0.3, 0.4)), correction: v))
        check(b.x > a.x * 1.9, "Measured red separation must survive adaptation")
        let clipped = FinishingMath.working(.init(0.2, 1, 0.9))
        check(simd_length(FinishingMath.color(clipped, correction: v) - clipped) < 0.00001,
              "A clipped exposure anchor must not drive channel adaptation")
        // A reliable, lit subject with a dim red channel: a hard RGB offset would
        // erase red even though the pixel as a whole is well exposed.
        v.referenceGains = .init(0.05, 0.7, 0.7); v.brightness = -0.08; v.contrast = 1.04
        let shadow = FinishingMath.color(.init(repeating: 0.3), correction: v)
        check(shadow.min() > 0, "Soft toe must preserve a dim channel on an adapted surface")
        print("PASS: \(cases) native checks; Metal/CPU parity, reference evidence, original/neutral preservation, colour separation, shadow detail")
    }
}
