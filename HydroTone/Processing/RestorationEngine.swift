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
        corrected = source + (corrected - source) * recovery
        return RestorationPixelResult(color: finite(corrected), hitTransmissionFloor: hitFloor, hitMaximumGain: hitGain)
    }

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
        var values = map.values
        let data = values.withUnsafeMutableBytes { Data($0) }
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
        let amount = min(1, max(0, settings.intensity))
        guard settings.preset != .original, amount > 0 else { return image }
        let values = corrections(settings: settings, plan: plan)
        let current = filter.apply(image, correction: values.current, intensity: amount)
        let physicallyRestored = try restore(image, plan: plan)
        let finished = filter.finishing(physicallyRestored, correction: values.restored)
        let depthAware = filter.blend(image, finished, amount: amount)
        // Low-confidence fits approach the exact current HydroTone output.
        return filter.blend(current, depthAware, amount: values.restored.physicalWeight)
    }

    /// The correction values combined applies: one set for the source image, one for the restored image.
    func corrections(settings: FilterSettings, plan: RestorationPlan) -> (current: ColorCorrection, restored: ColorCorrection) {
        (ColorCorrection.make(analysis: settings.analysis, preset: settings.preset),
         ColorCorrection.make(analysis: settings.analysis, preset: settings.preset, plan: plan))
    }
}
