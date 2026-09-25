import CoreImage

struct RestorationPixelResult: Sendable, Equatable {
    let color: SIMD3<Float>
    let hitTransmissionFloor: Bool
    let hitMaximumGain: Bool
}

enum RestorationMath {
    static func forward(clear: SIMD3<Float>, depth: Float, backscatterInfinity: SIMD3<Float>,
                        betaDirect: SIMD3<Float>, betaBackscatter: SIMD3<Float>) -> SIMD3<Float> {
        let z = safe(depth, fallback: 0, range: 0...1)
        var result = SIMD3<Float>(repeating: 0)
        for channel in 0..<3 {
            let directTransmission = exp(-max(0, safe(betaDirect[channel])) * z)
            let backscatterTransmission = exp(-max(0, safe(betaBackscatter[channel])) * z)
            result[channel] = max(0, safe(clear[channel])) * directTransmission
                + max(0, safe(backscatterInfinity[channel])) * (1 - backscatterTransmission)
        }
        return finite(result)
    }

    static func inverse(observed: SIMD3<Float>, depth: Float, backscatterInfinity: SIMD3<Float>,
                        betaDirect: SIMD3<Float>, betaBackscatter: SIMD3<Float>,
                        limits: RestorationLimits, recoverability: SIMD3<Float> = .init(repeating: 1)) -> RestorationPixelResult {
        let source = finite(observed)
        let z = safe(depth, fallback: 0, range: 0...1)
        var corrected = SIMD3<Float>(repeating: 0)
        var hitFloor = false, hitGain = false
        for channel in 0..<3 {
            let directTransmission = exp(-max(0, safe(betaDirect[channel])) * z)
            let backscatterTransmission = exp(-max(0, safe(betaBackscatter[channel])) * z)
            let transmission = max(safe(limits.transmissionFloor, fallback: 0.28, range: 0.01...1), directTransmission)
            let maximumGain = safe(limits.maximumGain[channel], fallback: 1, range: 1...16)
            let gain = min(1 / transmission, maximumGain)
            hitFloor = hitFloor || directTransmission <= limits.transmissionFloor
            hitGain = hitGain || gain >= maximumGain - 1e-5
            let backscatter = max(0, safe(backscatterInfinity[channel])) * (1 - backscatterTransmission)
            corrected[channel] = max(0, source[channel] - backscatter) * gain
        }
        let sourcePeak = max(source.x, source.y, source.z)
        let highlight = smoothstep(limits.highlightStart, limits.highlightEnd, sourcePeak) * 0.8
        corrected = corrected * (1 - highlight) + source * highlight
        let maximumOutput = safe(limits.maximumOutput, fallback: 1.15, range: 0.5...8)
        corrected = SIMD3(min(maximumOutput, max(0, corrected.x)),
                          min(maximumOutput, max(0, corrected.y)),
                          min(maximumOutput, max(0, corrected.z)))
        let recovery = SIMD3(min(1, max(0, recoverability.x)), min(1, max(0, recoverability.y)),
                             min(1, max(0, recoverability.z)))
        corrected = keepHueWhereDark(source: source, restored: source + (corrected - source) * recovery)
        corrected = keepBlueFamily(source: source, restored: corrected)
        return RestorationPixelResult(color: finite(corrected), hitTransmissionFloor: hitFloor, hitMaximumGain: hitGain)
    }

    /// Where veil removal leaves little light (far water is mostly veil), the channel that lost
    /// least (often red, which is recovered least) would dominate and turn the water red-brown or
    /// violet. There the source colour is kept, scaled to the restored level. The level is the
    /// plain channel sum, because blue, which carries water colour, barely counts in luminance.
    static func keepHueWhereDark(source: SIMD3<Float>, restored: SIMD3<Float>) -> SIMD3<Float> {
        let before = pointwiseMax(source, .zero).sum(), after = pointwiseMax(restored, .zero).sum()
        guard before > 1e-5 else { return restored }
        let kept = after / before
        let dark = 1 - smoothstep(darkLow, darkHigh, kept)
        return finite(restored + (pointwiseMax(source, .zero) * kept - restored) * dark)
    }
    static let darkLow: Float = 0.3, darkHigh: Float = 0.6

    /// A near, pale subject in blue water (a silver fish) read at far-water depth, as the video
    /// path's one constant depth does, loses nearly all its blue to the veil and turns lime.
    /// So a blue pixel (blue above red and green) that comes out green (green above blue) only
    /// because its green/blue ratio grew several times keeps its source hue, at the restored
    /// level (channel sum). Green, yellow and grey sources, and ordinary colour recovery
    /// (a smaller ratio change), are untouched. The Metal kernel mirrors it.
    static func keepBlueFamily(source: SIMD3<Float>, restored: SIMD3<Float>) -> SIMD3<Float> {
        let lit = pointwiseMax(source, .zero), now = pointwiseMax(restored, .zero)
        guard lit.sum() > 1e-5 else { return restored }
        let blue = smoothstep(blueLow, blueHigh, lit.z / max(max(lit.x, lit.y), 1e-4))
        let greenBlue = now.y / max(now.z, 1e-4)
        let green = smoothstep(greenLow, greenHigh, greenBlue)
        let growth = smoothstep(growthLow, growthHigh, greenBlue / max(lit.y / max(lit.z, 1e-4), 1e-4))
        let amount = blue * green * growth
        return finite(restored + (lit * (now.sum() / lit.sum()) - restored) * amount)
    }
    static let blueLow: Float = 1.0, blueHigh: Float = 1.1
    static let greenLow: Float = 1.1, greenHigh: Float = 1.4
    static let growthLow: Float = 4, growthHigh: Float = 8

    static func confidenceBlend(current: SIMD3<Float>, restored: SIMD3<Float>, confidence: Float) -> SIMD3<Float> {
        let amount = safe(confidence, fallback: 0, range: 0...1)
        return finite(current) * (1 - amount) + finite(restored) * amount
    }

    private static func smoothstep(_ low: Float, _ high: Float, _ value: Float) -> Float {
        let width = max(1e-5, high - low)
        let x = min(1, max(0, (value - low) / width))
        return x * x * (3 - 2 * x)
    }

    private static func safe(_ value: Float, fallback: Float = 0, range: ClosedRange<Float>? = nil) -> Float {
        guard value.isFinite else { return fallback }
        guard let range else { return value }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    private static func finite(_ value: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(value.x.isFinite ? value.x : 0, value.y.isFinite ? value.y : 0, value.z.isFinite ? value.z : 0)
    }
}

final class RestorationEngine: Sendable {
    private let kernel: CIColorKernel?

    init() {
        let kernels = try? CIKernel.kernels(withMetalString: Self.metalSource)
        kernel = kernels?.first { $0.name == "HydroToneRestoration" } as? CIColorKernel
    }

    private static let metalSource = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    [[stitchable]] float4 HydroToneRestoration(coreimage::sample_t source,
                                                coreimage::sample_t depthSample,
                                                float4 backscatterInfinity,
                                                float4 betaDirect,
                                                float4 betaBackscatter,
                                                float4 limits,
                                                float4 maximumGain,
                                                float4 recoverability) {
        const float z = clamp(depthSample.r, 0.0f, 1.0f);
        const float3 directTransmission = exp(-max(betaDirect.rgb, float3(0.0f)) * z);
        const float3 backscatterTransmission = exp(-max(betaBackscatter.rgb, float3(0.0f)) * z);
        const float3 safeTransmission = max(directTransmission, float3(max(0.01f, limits.x)));
        const float3 gain = min(1.0f / safeTransmission, max(maximumGain.rgb, float3(1.0f)));
        const float3 backscatter = max(backscatterInfinity.rgb, float3(0.0f)) * (1.0f - backscatterTransmission);
        float3 restored = max(source.rgb - backscatter, float3(0.0f)) * gain;
        const float peak = max(source.r, max(source.g, source.b));
        const float highlight = smoothstep(limits.y, max(limits.y + 0.001f, limits.z), peak) * 0.8f;
        restored = mix(restored, source.rgb, highlight);
        restored = clamp(restored, float3(0.0f), float3(max(0.5f, limits.w)));
        restored = source.rgb + (restored - source.rgb) * clamp(recoverability.rgb, 0.0f, 1.0f);
        // Where veil removal leaves little light (channel sum), keep the source hue at the
        // restored level, so far water does not turn red-brown or violet.
        // RestorationMath.keepHueWhereDark mirrors it.
        const float3 lit = max(source.rgb, float3(0.0f));
        const float before = lit.r + lit.g + lit.b;
        if (before > 1e-5f) {
            const float3 now = max(restored, float3(0.0f));
            const float kept = (now.r + now.g + now.b) / before;
            restored = mix(restored, lit * kept, 1.0f - smoothstep(0.3f, 0.6f, kept));
        }
        // A blue source pixel that turned green only because the veil took nearly all its blue
        // (green/blue grew 4-8 times) keeps its source hue at the restored level.
        // RestorationMath.keepBlueFamily mirrors it.
        if (before > 1e-5f) {
            const float3 now = max(restored, float3(0.0f));
            const float blueness = smoothstep(1.0f, 1.1f, lit.b / max(max(lit.r, lit.g), 1e-4f));
            const float greenBlue = now.g / max(now.b, 1e-4f);
            const float growth = greenBlue / max(lit.g / max(lit.b, 1e-4f), 1e-4f);
            const float amount = blueness * smoothstep(1.1f, 1.4f, greenBlue) * smoothstep(4.0f, 8.0f, growth);
            restored = mix(restored, lit * ((now.r + now.g + now.b) / before), amount);
        }
        if (!all(isfinite(restored))) { restored = max(source.rgb, float3(0.0f)); }
        return float4(restored, source.a);
    }
    """

    func restore(_ image: CIImage, plan: RestorationPlan) throws -> CIImage {
        guard let kernel else { throw RestorationError.kernelUnavailable }
        let depth = try depthImage(plan.depth, matching: image.extent)
        let limits = plan.limits
        let output = kernel.apply(extent: image.extent, arguments: [
            image, depth,
            vector(plan.backscatterInfinity), vector(plan.betaDirect), vector(plan.betaBackscatter),
            CIVector(x: CGFloat(limits.transmissionFloor), y: CGFloat(limits.highlightStart),
                     z: CGFloat(limits.highlightEnd), w: CGFloat(limits.maximumOutput)),
            vector(limits.maximumGain), vector(plan.channelRecoverability)
        ])
        guard let output else { throw RestorationError.kernelUnavailable }
        return output.cropped(to: image.extent)
    }

    private func depthImage(_ map: NormalizedDepthMap, matching extent: CGRect) throws -> CIImage {
        let data = map.values.withUnsafeBytes { Data($0) }
        let depth = CIImage(bitmapData: data, bytesPerRow: map.width * MemoryLayout<Float>.size,
                            size: CGSize(width: map.width, height: map.height), format: .Rf, colorSpace: nil)
        let scaled = depth.transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(map.width),
                                                             y: extent.height / CGFloat(map.height)))
        return scaled.transformed(by: CGAffineTransform(translationX: extent.minX - scaled.extent.minX,
                                                        y: extent.minY - scaled.extent.minY))
    }

    private func vector(_ value: SIMD3<Float>) -> CIVector {
        CIVector(x: CGFloat(value.x), y: CGFloat(value.y), z: CGFloat(value.z), w: 0)
    }

    func combined(_ image: CIImage, plan: RestorationPlan, settings: FilterSettings,
                  filter: FilterEngine) throws -> CIImage {
        let amount = min(1, max(0, settings.appliedIntensity))
        guard settings.preset != .original, amount > 0 else { return image }
        let values = corrections(settings: settings, plan: plan)
        let current = filter.apply(image, correction: values.current, intensity: amount)
        let physicallyRestored = try restore(image, plan: plan)
        let finished = filter.finishing(physicallyRestored, correction: values.restored, reference: image)
        let depthAware = filter.blend(image, finished, amount: amount)
        // Low-confidence fits approach the exact current HydroTone output.
        return filter.blend(current, depthAware, amount: values.restored.physicalWeight)
    }

    /// The correction values combined applies: one set for the source image, one for the restored image.
    func corrections(settings: FilterSettings, plan: RestorationPlan) -> (current: ColorCorrection, restored: ColorCorrection) {
        (ColorCorrection.make(analysis: settings.analysis, preset: settings.preset, adjustments: settings.adjustments),
         ColorCorrection.make(analysis: settings.analysis, preset: settings.preset, plan: plan, adjustments: settings.adjustments))
    }
}
