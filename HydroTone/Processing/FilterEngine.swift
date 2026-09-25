import CoreImage
import CoreImage.CIFilterBuiltins
import Metal

// Immutable settings are shared by preview and export. Analysis never changes per video frame.
enum DivePreset: String, CaseIterable, Identifiable, Sendable {
    case original = "Original", natural = "Natural Dive"
    case tropical = "Tropical", deep = "Deep Dive"
    var id: String { rawValue }
    var localizedName: String { String(localized: String.LocalizationValue(rawValue)) }
    var restoration: Float {
        switch self { case .original: 0; case .natural: 0.45; case .tropical: 0.42; case .deep: 0.50 }
    }
    var vibrance: Float {
        switch self { case .original: 0; case .natural: 0.18; case .tropical: 0.30; case .deep: 0.24 }
    }
    var castRemoval: Float {
        switch self { case .original: 0; case .natural: 0.16; case .tropical: 0.12; case .deep: 0.18 }
    }
    var contrast: Float {
        switch self { case .original: 1; case .natural: 1.04; case .tropical: 1.06; case .deep: 1.10 }
    }
    var saturation: Float {
        switch self { case .original: 1; case .natural: 1.08; case .tropical: 1.18; case .deep: 1.14 }
    }
    var clarity: Float {
        switch self { case .original: 0; case .natural: 0.16; case .tropical: 0.19; case .deep: 0.25 }
    }
    var symbolName: String {
        switch self {
        case .original: "circle.lefthalf.filled"
        case .natural: "water.waves"
        case .tropical: "sun.max.fill"
        case .deep: "drop.fill"
        }
    }
}
struct WaterAnalysis: Sendable, Equatable {
    var redLoss: Float = 0
    var cyanDominance: Float = 0
    var exposure: Float = 0
    var contrast: Float = 0
    var saturation: Float = 0
    // Scene mean colour (linear) and median luminance. Zero means stay neutral: no cast step.
    var meanRed: Float = 0
    var meanGreen: Float = 0
    var meanBlue: Float = 0
    var midLuminance: Float = 0.18
    /// Green over blue in the scene mean. Above one the water reads green, not blue.
    var greenOverBlue: Float { meanBlue > 0.001 && meanGreen > 0.001 ? meanGreen / meanBlue : 1 }
    static let neutral = WaterAnalysis()
    /// Every stored value. median, sceneMean and sceneInliers walk this list, so a new field
    /// must be added here or video silently gets its default.
    static var fields: [WritableKeyPath<Self, Float>] { [\.redLoss, \.cyanDominance, \.exposure, \.contrast, \.saturation,
                                                        \.meanRed, \.meanGreen, \.meanBlue, \.midLuminance] }
    static func median(_ samples: [Self]) -> Self {
        guard !samples.isEmpty else { return .neutral }
        var result = Self()
        for key in fields { result[keyPath: key] = samples.map { $0[keyPath: key] }.sorted()[samples.count / 2] }
        return result
    }
    /// Indices of the samples that describe the same scene. A sample is dropped whole when any
    /// field sits far from the other samples (an above-water or surface frame is odd in every
    /// field). Score = largest |value - median| / max(MAD, floor). At least half always stay.
    static func sceneInliers(_ samples: [Self], threshold: Float = 4, floor: Float = 0.02) -> [Int] {
        guard samples.count >= 3 else { return Array(samples.indices) }
        func middle(_ values: [Float]) -> Float {
            let sorted = values.sorted(), half = sorted.count / 2
            return sorted.count % 2 == 1 ? sorted[half] : (sorted[half - 1] + sorted[half]) / 2
        }
        var scores = [Float](repeating: 0, count: samples.count)
        for key in fields {
            let values = samples.map { $0[keyPath: key].isFinite ? $0[keyPath: key] : 0 }
            let center = middle(values)
            let spread = max(middle(values.map { abs($0 - center) }), floor)
            for index in values.indices { scores[index] = max(scores[index], abs(values[index] - center) / spread) }
        }
        let kept = samples.indices.filter { scores[$0] <= threshold }
        let minimum = (samples.count + 1) / 2
        guard kept.count < minimum else { return kept }
        // Too many odd samples means the clip itself varies. Keep the most typical half.
        return samples.indices.sorted { (scores[$0], $0) < (scores[$1], $1) }.prefix(minimum).sorted()
    }
    /// Mean of the kept samples. Out-of-range indices are ignored; none left means all samples.
    static func sceneMean(_ samples: [Self], keeping: [Int]) -> Self {
        let valid = keeping.filter { samples.indices.contains($0) }
        let chosen = valid.isEmpty ? Array(samples.indices) : valid
        guard !chosen.isEmpty else { return .neutral }
        var result = Self()
        for key in fields {
            result[keyPath: key] = chosen.reduce(Float(0)) { $0 + (samples[$1][keyPath: key].isFinite ? samples[$1][keyPath: key] : 0) } / Float(chosen.count)
        }
        return result
    }
}
struct FilterSettings: Sendable, Equatable {
    var preset: DivePreset = .natural
    var intensity: Float = 0.8
    var analysis: WaterAnalysis = .neutral
}

/// Scene-level correction values. Analysis makes them once per photo or video scene, and
/// FilterEngine only applies them, so every frame of a clip gets the same look.
struct ColorCorrection: Sendable, Equatable {
    /// Linear per-channel gains: green-to-blue cast shift plus the red boost.
    var castGains = SIMD3<Float>(repeating: 1)
    /// Red rebuilt from green, as a share of green, where a pixel's green/blue ratio is inside the gate.
    var redRebuild: Float = 0
    var redGateLow: Float = 0.55
    var redGateHigh: Float = 0.95
    /// Red/green ratio of the water after the gains. Redder pixels count as subject and get more red.
    var subjectRed: Float = 1
    /// Mid-tone lift on gamma luminance. Black and white stay fixed.
    var midLift: Float = 0
    /// S-curve strength on gamma luminance and its pivot (scene median, gamma encoded).
    var toneCurve: Float = 0
    var tonePivot: Float = 0.45
    var brightness: Float = 0
    var contrast: Float = 1
    var saturation: Float = 1
    var shadowLift: Float = 0
    var highlightAmount: Float = 1
    /// Fine clarity and broad definition (unsharp masks). Radii are shares of the short image
    /// side, so preview, export and video frames of any size look the same.
    var clarity: Float = 0
    var clarityRadius: Float = 0.011
    var definition: Float = 0
    var definitionRadius: Float = 0.04
    /// Colour temperature shift in kelvin.
    var warmth: Float = 0
    var vibrance: Float = 0
    /// Weight of the depth-aware path in RestorationEngine.combined (the plan confidence).
    var physicalWeight: Float = 0
    static let identity = ColorCorrection()

    /// The one place that turns measurements into correction values. Pure and deterministic.
    /// Without a plan it describes the current path (the source image). With a plan it describes
    /// finishing of the restored image, which lost the veil light and so needs a mid-tone lift.
    static func make(analysis: WaterAnalysis, preset: DivePreset, plan: RestorationPlan? = nil) -> Self {
        guard preset != .original else { return .identity }
        var v = Self()
        // Cast values come from the source colour on both paths. A plan-based estimate of the
        // restored colour was tried and is biased: it read violet restored water as green.
        let mean = SIMD3(analysis.meanRed, analysis.meanGreen, analysis.meanBlue)
        let restore = preset.restoration * min(0.9, max(0, analysis.redLoss))
        // Low global contrast is a reliable proxy for the veil users call underwater haze.
        let haze = min(1, max(0, (0.34 - analysis.contrast) / 0.28))
        // Green water: pull the scene mean toward a blue-leaning cyan. The 0.88 green/blue
        // target is approximate, tuned by eye; below it the water already reads blue.
        // Only a coloured cast is shifted: a neutral scene (mean chroma near 0) keeps its greys neutral.
        let greenBlue = analysis.greenOverBlue
        let peak = max(mean.x, mean.y, mean.z)
        let chroma = peak > 0.001 ? (peak - min(mean.x, mean.y, mean.z)) / peak : 0
        let waterCast = min(1, max(0, (chroma - 0.05) / 0.2))
        let shift = greenBlue > 0.88 ? pow(0.88 / greenBlue, min(1, 0.6 + preset.castRemoval * 1.5) * waterCast) : 1
        var gains = SIMD3<Float>(1 + restore * 0.9, max(0.65, sqrt(shift)), min(1.7, 1 / sqrt(shift)))
        // Keep the mean luminance, so this step changes colour and not exposure.
        let before = (mean * luma).sum(), after = (mean * gains * luma).sum()
        if before > 0.001, after > 0.001 { gains *= min(1.25, max(0.8, before / after)) }
        v.castGains = gains
        v.subjectRed = mean.y * gains.y > 0.001 ? mean.x * gains.x / (mean.y * gains.y) : 1
        v.redRebuild = restore * 0.72
        v.tonePivot = min(0.6, max(0.3, pow(max(0, analysis.midLuminance), 1 / 2.2)))
        // 0.3 keeps the curve monotonic for any pivot in 0.3...0.6.
        v.toneCurve = min(0.3, max(0, (preset.contrast - 1) * 2 + 0.12 + haze * 0.12))
        v.brightness = analysis.exposure * 0.45
        v.contrast = preset.contrast + haze * 0.05
        v.saturation = preset.saturation + haze * 0.10
        // Global contrast alone can bury a dark diver or reef, so lift the lower tones.
        v.shadowLift = 0.28 + haze * 0.22
        v.highlightAmount = 0.92
        // Clarity restores local separation lost to backscatter without inventing texture.
        // Definition works at a broader scale, on the veil over distant water and reef.
        v.clarity = preset.clarity * (0.65 + haze * 0.35) * 1.2
        v.clarityRadius = (5 + haze * 3) / 480
        v.definition = preset.clarity * (0.5 + haze * 0.8)
        v.warmth = preset == .tropical ? 300 : 0
        v.vibrance = preset.vibrance * max(0.3, 1 - analysis.saturation)
        if let plan {
            v.physicalWeight = plan.confidence
            // Give back the light the restored image lost with the veil: move its estimated
            // median luminance toward the source median times a small brightness goal, but
            // never above 0.22 (about L* 54), so bright scenes are not lifted further.
            let before = (mean * luma).sum(), after = (restoredMean(mean, plan: plan) * luma).sum()
            let ratio = before > 0.001 ? min(1.5, max(0.2, after / before)) : 1
            let restoredMid = analysis.midLuminance * ratio
            v.midLift = midLift(from: restoredMid, to: min(analysis.midLuminance * 1.2, max(restoredMid, 0.22)))
        }
        return v.sanitized()
    }

    /// Luminance weights, the same ones analyze() and the kernels use.
    static let luma = SIMD3<Float>(0.2126, 0.7152, 0.0722)

    /// Scene mean colour after restoration, at the plan's mean depth. It mirrors the
    /// restoration kernel on the scene mean colour and ignores highlight protection.
    static func restoredMean(_ mean: SIMD3<Float>, plan: RestorationPlan) -> SIMD3<Float> {
        let values = plan.depth.values
        let z = values.isEmpty ? 0.5 : values.reduce(0, +) / Float(values.count)
        var restored = mean
        for channel in 0..<3 {
            let veil = max(0, plan.backscatterInfinity[channel]) * (1 - exp(-max(0, plan.betaBackscatter[channel]) * z))
            let transmission = max(max(0.01, plan.limits.transmissionFloor), exp(-max(0, plan.betaDirect[channel]) * z))
            let gain = min(1 / transmission, max(1, plan.limits.maximumGain[channel]))
            let recovery = min(1, max(0, plan.channelRecoverability[channel]))
            restored[channel] = mean[channel] + (max(0, mean[channel] - veil) * gain - mean[channel]) * recovery
        }
        return restored.x.isFinite && restored.y.isFinite && restored.z.isFinite ? restored : mean
    }

    /// Lift strength that moves linear luminance `from` to `to` with y = x + lift * x * (1 - x) in
    /// gamma space. Capped at 0.9 so the curve stays monotonic; zero when no lift is needed.
    static func midLift(from: Float, to: Float) -> Float {
        let x0 = pow(min(1, max(1e-4, from)), 1 / 2.2), x1 = pow(min(1, max(1e-4, to)), 1 / 2.2)
        guard x1 > x0, x0 < 0.999 else { return 0 }
        return min(0.9, (x1 - x0) / (x0 * (1 - x0)))
    }

    private func sanitized() -> Self {
        var v = self
        let fallback = Self.identity
        func fix(_ key: WritableKeyPath<Self, Float>) { if !v[keyPath: key].isFinite { v[keyPath: key] = fallback[keyPath: key] } }
        for key in [\Self.redRebuild, \.redGateLow, \.redGateHigh, \.subjectRed, \.midLift, \.toneCurve, \.tonePivot,
                    \.brightness, \.contrast, \.saturation, \.shadowLift, \.highlightAmount, \.clarity, \.clarityRadius,
                    \.definition, \.definitionRadius, \.warmth, \.vibrance, \.physicalWeight] { fix(key) }
        if !(v.castGains.x.isFinite && v.castGains.y.isFinite && v.castGains.z.isFinite) { v.castGains = fallback.castGains }
        v.midLift = min(0.9, max(0, v.midLift))
        v.toneCurve = min(0.3, max(0, v.toneCurve))
        v.physicalWeight = min(1, max(0, v.physicalWeight))
        return v
    }

    #if DEBUG
    var logDescription: String {
        "gains=(\(castGains.x),\(castGains.y),\(castGains.z)) redRebuild=\(redRebuild) subjectRed=\(subjectRed) midLift=\(midLift) curve=\(toneCurve)@\(tonePivot) brightness=\(brightness) contrast=\(contrast) saturation=\(saturation) shadows=\(shadowLift) clarity=\(clarity) definition=\(definition) warmth=\(warmth) vibrance=\(vibrance) physicalWeight=\(physicalWeight)"
    }
    #endif
}

/// CPU mirror of the HydroToneFinishColor kernel. Unit tests use it; keep both equal.
enum FinishingMath {
    static func color(_ source: SIMD3<Float>, correction v: ColorCorrection) -> SIMD3<Float> {
        func smoothstep(_ low: Float, _ high: Float, _ x: Float) -> Float {
            let t = min(1, max(0, (x - low) / max(1e-5, high - low)))
            return t * t * (3 - 2 * t)
        }
        let input = SIMD3(source.x.isFinite ? max(0, source.x) : 0, source.y.isFinite ? max(0, source.y) : 0,
                          source.z.isFinite ? max(0, source.z) : 0)
        var c = input * SIMD3(max(0, v.castGains.x), max(0, v.castGains.y), max(0, v.castGains.z))
        let greenBlue = c.y / max(c.z, 1e-4)
        let hue = smoothstep(v.redGateLow, v.redGateHigh, greenBlue) * (1 - smoothstep(1.35, 2.2, greenBlue))
        let subject = smoothstep(v.subjectRed, v.subjectRed + 0.3, c.x / max(c.y, 1e-4))
        c.x += max(v.redRebuild, 0) * c.y * hue * (0.3 + 0.7 * subject)
        let l = (c * ColorCorrection.luma).sum()
        if l > 1e-5 && l < 1 {
            var x = pow(l, 1 / 2.2)
            x += max(0, v.midLift) * x * (1 - x)
            let y = min(1, max(0, x + 4 * v.toneCurve * (x - v.tonePivot) * x * (1 - x)))
            let peak = c.max()
            c *= min(pow(y, 2.2) / l, max(1, peak) / max(peak, 1e-5))
        }
        return c.x.isFinite && c.y.isFinite && c.z.isFinite ? c : input
    }
}

final class FilterEngine: Sendable {
    // CIContext is thread safe. CIFilters are local to each invocation.
    let context: CIContext
    private let colorKernel: CIColorKernel?
    static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    static let photoSpace = CGColorSpace(name: CGColorSpace.displayP3)!
    init() {
        let options: [CIContextOption: Any] = [.workingColorSpace: Self.workingSpace, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false]
        if let device = MTLCreateSystemDefaultDevice() { context = CIContext(mtlDevice: device, options: options) }
        else { context = CIContext(options: options) }
        let kernels = try? CIKernel.kernels(withMetalString: Self.colorSource)
        colorKernel = kernels?.first { $0.name == "HydroToneFinishColor" } as? CIColorKernel
    }

    // Scene-level colour stage: cast gains, hue-gated red rebuild, mid-tone lift, luminance S-curve.
    // Every argument comes from one ColorCorrection, so video frames share one curve.
    // FinishingMath.color is the CPU mirror.
    private static let colorSource = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    [[stitchable]] float4 HydroToneFinishColor(coreimage::sample_t source, float4 gains, float4 red, float4 tone) {
        float3 c = max(source.rgb, float3(0.0f)) * max(gains.rgb, float3(0.0f));
        // Rebuild red from green only where green is near blue. Blue water gets almost none,
        // so it cannot drift to violet. Strongly green pixels also get little, so green
        // water and weed do not turn yellow. Pixels redder than the water mean get the most.
        const float greenBlue = c.g / max(c.b, 1e-4f);
        const float hue = smoothstep(red.y, red.z, greenBlue) * (1.0f - smoothstep(1.35f, 2.2f, greenBlue));
        const float subject = smoothstep(red.w, red.w + 0.3f, c.r / max(c.g, 1e-4f));
        c.r += max(red.x, 0.0f) * c.g * hue * (0.3f + 0.7f * subject);
        // Mid-tone lift, then an S-curve around the scene median, both on gamma luminance.
        // Zero and one stay fixed.
        const float l = dot(c, float3(0.2126f, 0.7152f, 0.0722f));
        if (l > 1e-5f && l < 1.0f) {
            float x = pow(l, 1.0f / 2.2f);
            x += max(tone.z, 0.0f) * x * (1.0f - x);
            const float y = clamp(x + 4.0f * tone.x * (x - tone.y) * x * (1.0f - x), 0.0f, 1.0f);
            const float peak = max(c.r, max(c.g, c.b));
            // Cap the gain so no channel crosses one, and HDR peaks above one never grow.
            c *= min(pow(y, 2.2f) / l, max(1.0f, peak) / max(peak, 1e-5f));
        }
        if (!all(isfinite(c))) { c = max(source.rgb, float3(0.0f)); }
        return float4(c, source.a);
    }
    """

    func apply(_ image: CIImage, settings: FilterSettings) -> CIImage {
        guard settings.preset != .original else { return image }
        return apply(image, correction: .make(analysis: settings.analysis, preset: settings.preset), intensity: settings.intensity)
    }
    func apply(_ image: CIImage, correction: ColorCorrection, intensity: Float) -> CIImage {
        let amount = min(1, max(0, intensity.isFinite ? intensity : 0))
        guard amount > 0 else { return image }
        return blend(image, finishing(image, correction: correction), amount: amount)
    }
    /// Applies a preset at full strength. Callers choose what the final intensity blends against.
    func finishing(_ image: CIImage, settings: FilterSettings) -> CIImage {
        guard settings.preset != .original else { return image }
        return finishing(image, correction: .make(analysis: settings.analysis, preset: settings.preset))
    }
    /// Applies correction values at full strength. No values are derived here.
    func finishing(_ image: CIImage, correction v: ColorCorrection) -> CIImage {
        guard v != .identity else { return image }
        var corrected = colorStage(image, v)

        let controls = CIFilter.colorControls()
        controls.inputImage = corrected
        controls.contrast = v.contrast
        controls.saturation = v.saturation
        controls.brightness = v.brightness
        corrected = controls.outputImage ?? corrected

        let shadows = CIFilter.highlightShadowAdjust()
        shadows.inputImage = corrected
        shadows.shadowAmount = v.shadowLift
        shadows.highlightAmount = v.highlightAmount
        corrected = shadows.outputImage ?? corrected

        let side = Float(min(image.extent.width, image.extent.height))
        let short = side.isFinite && side > 0 ? side : 480
        for (amount, radius) in [(v.clarity, v.clarityRadius), (v.definition, v.definitionRadius)] where amount > 0 {
            let mask = CIFilter.unsharpMask()
            mask.inputImage = corrected
            mask.radius = max(1, radius * short)
            mask.intensity = amount
            corrected = mask.outputImage ?? corrected
        }

        if v.warmth != 0 {
            let warmth = CIFilter.temperatureAndTint()
            warmth.inputImage = corrected
            warmth.neutral = CIVector(x: 6500, y: 0)
            warmth.targetNeutral = CIVector(x: CGFloat(6500 + v.warmth), y: 0)
            corrected = warmth.outputImage ?? corrected
        }
        let vibrance = CIFilter.vibrance()
        vibrance.inputImage = corrected
        vibrance.amount = v.vibrance
        corrected = vibrance.outputImage ?? corrected
        return corrected.cropped(to: image.extent)
    }
    private func colorStage(_ image: CIImage, _ v: ColorCorrection) -> CIImage {
        guard let colorKernel else {
            // Without the kernel keep the gains and a plain red rebuild; the tone curve is skipped.
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            matrix.rVector = CIVector(x: CGFloat(v.castGains.x), y: CGFloat(v.redRebuild * v.castGains.y * 0.3), z: 0, w: 0)
            matrix.gVector = CIVector(x: 0, y: CGFloat(v.castGains.y), z: 0, w: 0)
            matrix.bVector = CIVector(x: 0, y: 0, z: CGFloat(v.castGains.z), w: 0)
            return matrix.outputImage ?? image
        }
        return colorKernel.apply(extent: image.extent, arguments: [
            image, CIVector(x: CGFloat(v.castGains.x), y: CGFloat(v.castGains.y), z: CGFloat(v.castGains.z), w: 0),
            CIVector(x: CGFloat(v.redRebuild), y: CGFloat(v.redGateLow), z: CGFloat(v.redGateHigh), w: CGFloat(v.subjectRed)),
            CIVector(x: CGFloat(v.toneCurve), y: CGFloat(v.tonePivot), z: CGFloat(v.midLift), w: 0)
        ]) ?? image
    }
    func blend(_ source: CIImage, _ target: CIImage, amount: Float) -> CIImage {
        // Dissolve interpolates complete results: 0 is exactly the source, 1 the target.
        let blend = CIFilter.dissolveTransition()
        blend.inputImage = source
        blend.targetImage = target
        blend.time = min(1, max(0, amount))
        return (blend.outputImage ?? source).cropped(to: source.extent)
    }
    func sdr(_ image: CIImage) -> CIImage {
        guard image.contentHeadroom > 1 else { return image }
        let tone = CIFilter.toneMapHeadroom()
        tone.inputImage = image
        tone.sourceHeadroom = image.contentHeadroom
        tone.targetHeadroom = 1
        return tone.outputImage ?? image
    }
    func analyze(_ image: CIImage) -> WaterAnalysis {
        let source = sdr(image)
        let extent = source.extent
        guard !extent.isEmpty, extent.width.isFinite, extent.height.isFinite else { return .neutral }
        let size = 48
        let scaled = source.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(size) / extent.width, y: CGFloat(size) / extent.height))
        var pixels = [Float](repeating: 0, count: size * size * 4)
        context.render(scaled, toBitmap: &pixels, rowBytes: size * 4 * MemoryLayout<Float>.size,
                       bounds: CGRect(x: 0, y: 0, width: size, height: size), format: .RGBAf, colorSpace: Self.workingSpace)
        var red: Float = 0, green: Float = 0, blue: Float = 0, luminance: [Float] = [], saturation: Float = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = pixels[i], g = pixels[i+1], b = pixels[i+2]
            let l = r * 0.2126 + g * 0.7152 + b * 0.0722
            guard l.isFinite, l > 0.015, l < 0.85 else { continue }
            red += max(0, r); green += max(0, g); blue += max(0, b); luminance.append(l)
            let top = max(r, g, b)
            saturation += top > 0 ? (top - min(r, g, b)) / top : 0
        }
        guard !luminance.isEmpty else { return .neutral }
        luminance.sort()
        let n = Float(luminance.count)
        let surviving = max(0.001, (green + blue) / 2)
        let loss = max(0, min(1, 1 - red / surviving))
        return WaterAnalysis(redLoss: loss, cyanDominance: max(0, min(1, (surviving - red) / surviving)),
            exposure: min(0.12, max(0, (0.22 - luminance[luminance.count/2]) * 0.6)),
            contrast: luminance[luminance.count * 9 / 10] - luminance[luminance.count / 10], saturation: saturation / n,
            meanRed: red / n, meanGreen: green / n, meanBlue: blue / n, midLuminance: luminance[luminance.count / 2])
    }
}
