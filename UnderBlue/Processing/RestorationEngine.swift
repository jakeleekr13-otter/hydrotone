import CoreImage
import CoreImage.CIFilterBuiltins

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

    /// `broad` is the broad light around the pixel and `veilLevel` the plan's water level, for the
    /// local veil (localVeil). Without them the plan's veil is used as it is.
    static func inverse(observed: SIMD3<Float>, depth: Float, backscatterInfinity: SIMD3<Float>,
                        betaDirect: SIMD3<Float>, betaBackscatter: SIMD3<Float>,
                        limits: RestorationLimits, recoverability: SIMD3<Float> = .init(repeating: 1),
                        broad: SIMD3<Float>? = nil, veilLevel: Float = 0) -> RestorationPixelResult {
        let source = finite(observed)
        let z = safe(depth, fallback: 0, range: 0...1)
        var corrected = SIMD3<Float>(repeating: 0)
        var hitFloor = false, hitGain = false
        var veil = SIMD3<Float>(repeating: 0)
        for channel in 0..<3 {
            veil[channel] = max(0, safe(backscatterInfinity[channel])) * (1 - exp(-max(0, safe(betaBackscatter[channel])) * z))
        }
        if let broad { veil = localVeil(veil, broad: finite(broad), level: veilLevel) }
        for channel in 0..<3 {
            let directTransmission = exp(-max(0, safe(betaDirect[channel])) * z)
            let transmission = max(safe(limits.transmissionFloor, fallback: 0.28, range: 0.01...1), directTransmission)
            let maximumGain = safe(limits.maximumGain[channel], fallback: 1, range: 1...16)
            let gain = min(1 / transmission, maximumGain)
            hitFloor = hitFloor || directTransmission <= limits.transmissionFloor
            hitGain = hitGain || gain >= maximumGain - 1e-5
            corrected[channel] = max(0, source[channel] - veil[channel]) * gain
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

    /// Local veil. One veil per scene does not fit water whose light changes across the frame:
    /// toward the sun the real veil is brighter, and behind a fish school it is darker. With one veil,
    /// sunlit water kept a grey-pink band and the school turned into a hard shadow (challenge video,
    /// 32 to 38 s, 30 Sep 2026). So the veil scales with the broad light around the pixel (a blur of
    /// localVeilRadius of the short side), as a share of the scene's water level (RestorationPlan.veilLevel),
    /// within localVeilRange (localVeilScale).
    /// Its colour follows the broad light too, at the same luminance. In open water the water itself
    /// shows the veil's colour. The scene veil was bluer than whitish surface light, so taking it away
    /// left red and blue: video2's surface light turned pink or violet on 12.7% of the frame at 0 s
    /// (1.1% with the colour following). A level of zero means no local veil. The kernel mirrors it.
    static func localVeil(_ veil: SIMD3<Float>, broad: SIMD3<Float>, level: Float) -> SIMD3<Float> {
        guard level > 1e-4 else { return veil }
        let light = pointwiseMax(broad, .zero), broadLuminance = (light * ColorCorrection.luma).sum()
        let scaled = veil * localVeilScale(broadLuminance: broadLuminance, level: level)
        guard broadLuminance > 1e-4 else { return scaled }
        return light * ((scaled * ColorCorrection.luma).sum() / broadLuminance)
    }
    static func localVeilScale(broadLuminance: Float, level: Float) -> Float {
        guard level > 1e-4, broadLuminance.isFinite else { return 1 }
        return min(localVeilRange.upperBound, max(localVeilRange.lowerBound, max(0, broadLuminance) / level))
    }
    static let localVeilRadius: Float = 0.05
    static let localVeilRange: ClosedRange<Float> = 0.33...3

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
    private let detailKernel: CIColorKernel?
    private let depthBlendKernel: CIColorKernel?
    /// Depth (normalized) from which a pixel takes the full restored result. See combined().
    static let nearDepth: Float = 0.25

    init() {
        kernel = MetalKernels.color("UnderBlueRestoration")
        detailKernel = MetalKernels.color("UnderBlueRestoredDetail")
        depthBlendKernel = MetalKernels.color("UnderBlueDepthBlend")
    }

    /// The blur (share of the short side, at least 1.5 px) that splits the source into the part
    /// the restoration acts on and the fine detail. See restore(_:plan:).
    static let detailSplitRadius: Float = 0.0015

    /// The restoration removes the veil and divides by the transmission. On fine detail that is
    /// mostly noise: the veil takes signal, not noise, and the division then scales both. Far water
    /// got about twice the noise per signal (IMG_7260, 28 Sep 2026). So the restoration acts on a
    /// slightly blurred source, and the source's fine detail comes back at the pixel's own
    /// restoration ratio. The mean colour is the same; detail keeps its share of the signal.
    func restore(_ image: CIImage, plan: RestorationPlan) throws -> CIImage {
        guard let kernel else { throw RestorationError.kernelUnavailable }
        let depth = try depthImage(plan.depth, matching: image.extent)
        let limits = plan.limits
        let short = Float(min(image.extent.width, image.extent.height))
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = image.clampedToExtent()
        blur.radius = max(1.5, Self.detailSplitRadius * (short.isFinite ? short : 0))
        let low = detailKernel == nil ? image : (blur.outputImage ?? image).cropped(to: image.extent)
        // The broad light around each pixel, for the local veil (RestorationMath.localVeil).
        let broadBlur = CIFilter.gaussianBlur()
        broadBlur.inputImage = image.clampedToExtent()
        broadBlur.radius = max(4, RestorationMath.localVeilRadius * (short.isFinite ? short : 0))
        let broad = (broadBlur.outputImage ?? image).cropped(to: image.extent)
        let restoredLow = kernel.apply(extent: image.extent, arguments: [
            low, depth, broad,
            vector(plan.backscatterInfinity), vector(plan.betaDirect), vector(plan.betaBackscatter),
            CIVector(x: CGFloat(limits.transmissionFloor), y: CGFloat(limits.highlightStart),
                     z: CGFloat(limits.highlightEnd), w: CGFloat(limits.maximumOutput)),
            vector(limits.maximumGain), vector(plan.channelRecoverability),
            CIVector(x: CGFloat(plan.veilLevel), y: CGFloat(RestorationMath.localVeilRange.lowerBound),
                     z: CGFloat(RestorationMath.localVeilRange.upperBound), w: 0)
        ])
        guard let restoredLow else { throw RestorationError.kernelUnavailable }
        guard let detailKernel, low !== image else { return restoredLow.cropped(to: image.extent) }
        let output = detailKernel.apply(extent: image.extent, arguments: [image, low, restoredLow, vector(limits.maximumGain)])
        return (output ?? restoredLow).cropped(to: image.extent)
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
        try combined(image, plan: plan, values: corrections(settings: settings, plan: plan),
                     settings: settings, filter: filter)
    }

    /// combined() with correction values the caller already made. Video mixes two scenes' values here.
    func combined(_ image: CIImage, plan: RestorationPlan,
                  values: (current: ColorCorrection, restored: ColorCorrection),
                  settings: FilterSettings, filter: FilterEngine) throws -> CIImage {
        let amount = min(1, max(0, settings.appliedIntensity))
        guard settings.preset != .original, amount > 0 else { return image }
        let current = filter.apply(image, correction: values.current, intensity: amount)
        let physicallyRestored = try restore(image, plan: plan)
        let finished = filter.finishing(physicallyRestored, correction: values.restored, reference: image)
        let depthAware = filter.blend(image, finished, amount: amount)
        // Low-confidence fits approach the exact current UnderBlue output. So do the nearest pixels
        // (depth 0 to nearDepth): the restoration leaves them almost as they are, but the restored
        // values are made for the restored water. On the sunfish's belly (depth 0) the restored
        // water tone turned the unrestored cyan green (28 Sep 2026, O3: hue 150 -> 200).
        // A constant-depth plan (video, one depth per scene) keeps one weight for the frame.
        let weight = values.restored.physicalWeight
        let values = plan.depth.values
        guard let nearest = values.min(), let farthest = values.max(), farthest - nearest > 0.05,
              let depthBlendKernel else {
            return filter.blend(current, depthAware, amount: weight)
        }
        let depth = try depthImage(plan.depth, matching: image.extent)
        let mixed = depthBlendKernel.apply(extent: image.extent, arguments: [current, depthAware, depth,
            CIVector(x: CGFloat(weight), y: CGFloat(Self.nearDepth), z: 0, w: 0)])
        return (mixed ?? filter.blend(current, depthAware, amount: weight)).cropped(to: image.extent)
    }

    /// The correction values combined applies: one set for the source image, one for the restored image.
    func corrections(settings: FilterSettings, plan: RestorationPlan) -> (current: ColorCorrection, restored: ColorCorrection) {
        (ColorCorrection.make(analysis: settings.analysis, preset: settings.preset, adjustments: settings.adjustments),
         ColorCorrection.make(analysis: settings.analysis, preset: settings.preset, plan: plan, adjustments: settings.adjustments))
    }
}
