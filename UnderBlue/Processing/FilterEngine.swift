import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import simd

final class FilterEngine: Sendable {
    // CIContext is thread safe. CIFilters are local to each invocation.
    let context: CIContext
    private let colorKernel: CIColorKernel?
    private let shoulderKernel: CIColorKernel?
    private let detailKernel: CIColorKernel?
    private let lumaKernel: CIColorKernel?
    private let offsetKernel: CIColorKernel?
    private let lightDetailKernel: CIColorKernel?
    /// False when the finishing kernel failed to load. Output then uses the weaker colour-matrix
    /// fallback, so owners with a DiagnosticRecorder report it.
    var finishingKernelAvailable: Bool { colorKernel != nil }
    /// The detail kernel, for the kernel-versus-mirror test (finishing on a solid image cannot exercise it).
    var detailKernelForTesting: CIColorKernel? { detailKernel }
    var lumaKernelForTesting: CIColorKernel? { lumaKernel }
    var offsetKernelForTesting: CIColorKernel? { offsetKernel }
    static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    static let photoSpace = CGColorSpace(name: CGColorSpace.displayP3)!
    init() {
        let options: [CIContextOption: Any] = [.workingColorSpace: Self.workingSpace, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false]
        if let device = MTLCreateSystemDefaultDevice() { context = CIContext(mtlDevice: device, options: options) }
        else { context = CIContext(options: options) }
        colorKernel = MetalKernels.color("UnderBlueFinishColor")
        shoulderKernel = MetalKernels.color("UnderBlueHighlightShoulder")
        detailKernel = MetalKernels.color("UnderBlueDetail")
        lumaKernel = MetalKernels.color("UnderBlueLumaTransfer")
        offsetKernel = MetalKernels.color("UnderBlueBlackOffset")
        lightDetailKernel = MetalKernels.color("UnderBlueLightDetail")
    }

    func apply(_ image: CIImage, settings: FilterSettings) -> CIImage {
        guard settings.preset != .original else { return image }
        return apply(image, correction: .make(analysis: settings.analysis, preset: settings.preset, adjustments: settings.adjustments),
                     intensity: settings.appliedIntensity)
    }
    func apply(_ image: CIImage, correction: ColorCorrection, intensity: Float) -> CIImage {
        let amount = min(1, max(0, intensity.isFinite ? intensity : 0))
        guard amount > 0 else { return image }
        return blend(image, finishing(image, correction: correction), amount: amount)
    }
    /// Applies a preset at full strength. Callers choose what the final intensity blends against.
    func finishing(_ image: CIImage, settings: FilterSettings) -> CIImage {
        guard settings.preset != .original else { return image }
        return finishing(image, correction: .make(analysis: settings.analysis, preset: settings.preset, adjustments: settings.adjustments))
    }
    /// Applies correction values at full strength. No values are derived here.
    /// `reference` is the source image the highlight shoulder takes its ceiling from; it defaults to
    /// `image`. The restored path passes the unrestored source, so restoration cannot raise the ceiling.
    func finishing(_ image: CIImage, correction v: ColorCorrection, reference: CIImage? = nil) -> CIImage {
        guard v != .identity else { return image }
        var corrected = colorStage(image, v)

        let controls = CIFilter.colorControls()
        controls.inputImage = corrected
        // The colour-matrix fallback does not implement reference adaptation or its tone step.
        let referenceStrength = colorKernel == nil ? 0 : v.referenceStrength
        let gain = 1 + (v.contrast - 1) * (1 - referenceStrength), brightness = v.brightness * (1 - referenceStrength)
        controls.saturation = v.saturation
        // Contrast and brightness go through UnderBlueBlackOffset, which gives the shadows a toe
        // instead of clipping them (FinishingMath.blackOffset). Without the kernel, CIColorControls does it.
        if offsetKernel == nil { controls.contrast = gain; controls.brightness = brightness }
        corrected = controls.outputImage ?? corrected
        if let offsetKernel {
            corrected = offsetKernel.apply(extent: image.extent, arguments: [
                corrected, CIVector(x: CGFloat(gain), y: CGFloat(brightness + (1 - gain) * 0.5), z: 0, w: 0)
            ]) ?? corrected
        }

        // The filter reads a neighbourhood. Fed the frame as it is, it changed the edge band on the
        // restored path on the Mac: the challenge clip got a vignette (corners up to 0.13 OKLab L brighter
        // than the ring around the centre, 1 Oct 2026). A clamped input keeps the edges. iOS had the same
        // symptom from another cause (the reference input in colorStage); see docs/Verification.md.
        let shadows = CIFilter.highlightShadowAdjust()
        shadows.inputImage = corrected.clampedToExtent()
        shadows.shadowAmount = v.shadowLift
        shadows.highlightAmount = v.highlightAmount
        corrected = (shadows.outputImage ?? corrected).cropped(to: image.extent)

        let side = Float(min(image.extent.width, image.extent.height))
        let short = side.isFinite && side > 0 ? side : 480
        let unsharpened = corrected
        for (amount, radius) in [(v.clarity, v.clarityRadius), (v.definition, v.definitionRadius)] where amount > 0 {
            let mask = CIFilter.unsharpMask()
            mask.inputImage = corrected
            mask.radius = max(1, radius * short)
            mask.intensity = amount
            corrected = mask.outputImage ?? corrected
        }
        // Sharpen luminance only: on RGB the masks sharpen colour noise too. On the sunfish photo
        // (28 Sep 2026) this cut colour noise 27% in flat water and 34% on the fish; luminance was unchanged.
        if corrected !== unsharpened, let lumaKernel {
            corrected = lumaKernel.apply(extent: image.extent, arguments: [unsharpened, corrected]) ?? corrected
        }

        // Light rays inside bright light keep their contrast (FinishingMath.lightDetail). The kernel
        // gets the blur back from an unsharp mask (sharp = pixel + (pixel - blur)), as clarity does.
        // It runs here, before the fine detail. Placed last (after vibrance), with a blur or an unsharp
        // mask as its second input, it gave the Mac video path a vignette: the challenge clip's
        // frame edges up to 60 levels brighter, the centre unchanged (2 Oct 2026). The cause was
        // not found. The pixel values entering the kernel already had the bright edges.
        if let lightDetailKernel {
            let mask = CIFilter.unsharpMask()
            mask.inputImage = corrected
            mask.radius = max(2, FinishingMath.lightDetailRadius * short)
            mask.intensity = 1
            let sharp = (mask.outputImage ?? corrected).cropped(to: image.extent)
            corrected = lightDetailKernel.apply(extent: image.extent, arguments: [corrected, sharp,
                CIVector(x: CGFloat(FinishingMath.lightDetailAmount), y: CGFloat(FinishingMath.lightDetailLow),
                         z: CGFloat(FinishingMath.lightDetailHigh), w: 0),
                CIVector(x: CGFloat(FinishingMath.lightDetailEdgeLow), y: CGFloat(FinishingMath.lightDetailEdgeHigh), z: 0, w: 0)
            ]) ?? corrected
        }
        // Fine detail: the pixel against its own small blur, on subjects only (UnderBlueDetail). The blur
        // reads a clamped image, so the border gets no dark rim.
        if v.detail > 0, let detailKernel {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = corrected.clampedToExtent()
            blur.radius = max(0.5, v.detailRadius * short)
            let blurred = (blur.outputImage ?? corrected).cropped(to: image.extent)
            corrected = detailKernel.apply(extent: image.extent, arguments: [
                corrected, blurred, image,
                CIVector(x: CGFloat(v.castGains.x), y: CGFloat(v.castGains.y), z: CGFloat(v.castGains.z), w: 0),
                CIVector(x: CGFloat(v.waterRedness), y: CGFloat(v.waterChroma), z: 0, w: 0),
                CIVector(x: CGFloat(v.waterLit.x), y: CGFloat(v.waterLit.y), z: CGFloat(v.waterLit.z), w: 0),
                CIVector(x: CGFloat(v.detail), y: CGFloat(v.detailFloor), z: CGFloat(FinishingMath.detailEdgeLow), w: CGFloat(FinishingMath.detailEdgeHigh)),
                CIVector(x: CGFloat(FinishingMath.detailShadowLow), y: CGFloat(FinishingMath.detailShadowHigh), z: 0, w: 0)
            ]) ?? corrected
        }

        if v.warmth != 0 {
            let warmth = CIFilter.temperatureAndTint()
            warmth.inputImage = corrected
            // The source is taken as lit at 6500 K + warmth and rendered at 6500 K, so a positive value warms.
            // (6500 to 6500 + warmth cooled the image: +300 K turned grey blue.) A green tint of 1 per 100 K
            // makes the shift yellow rather than orange, so pale blue water does not turn lavender. A cool
            // shift (Custom's Temperature down) gets no tint: the mirrored magenta tint moved grey to indigo.
            warmth.neutral = CIVector(x: CGFloat(6500 + v.warmth), y: CGFloat(-max(0, v.warmth) / 100))
            warmth.targetNeutral = CIVector(x: 6500, y: 0)
            corrected = warmth.outputImage ?? corrected
        }
        let vibrance = CIFilter.vibrance()
        vibrance.inputImage = corrected
        vibrance.amount = v.vibrance
        corrected = vibrance.outputImage ?? corrected
        // Every step above can push highlights past white, and none rolls them off, so the shoulder runs last.
        if let shoulderKernel {
            corrected = shoulderKernel.apply(extent: image.extent, arguments: [
                corrected, reference ?? image,
                CIVector(x: CGFloat(FinishingMath.shoulderWidth), y: CGFloat(FinishingMath.whiteLow),
                         z: CGFloat(FinishingMath.whiteHigh), w: CGFloat(FinishingMath.paleLow)),
                CIVector(x: CGFloat(FinishingMath.paleHigh), y: 0, z: 0, w: 0)
            ]) ?? corrected
        }
        return corrected.cropped(to: image.extent)
    }
    private func colorStage(_ image: CIImage, _ v: ColorCorrection) -> CIImage {
        guard let colorKernel else {
            // Without the kernel keep the gains and a plain red rebuild; the tone curve is skipped.
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            let g = v.castGains * v.neutralGains
            matrix.rVector = CIVector(x: CGFloat(g.x), y: CGFloat(v.redRebuild * g.y * 0.3), z: 0, w: 0)
            matrix.gVector = CIVector(x: 0, y: CGFloat(g.y), z: 0, w: 0)
            matrix.bVector = CIVector(x: 0, y: 0, z: CGFloat(g.z), w: 0)
            return matrix.outputImage ?? image
        }
        // The reference-adapted contribution reads the same image. A smoothed copy (CINoiseReduction, or a
        // small blur) of the restored image as a second kernel input made iOS render the frame wrong: its
        // edge rows broke and the whole output got about 7% darker, even at a reference strength of 0.0009
        // (simulator and iPhone 17, 1 Oct 2026). The Mac renders it differently, so the harness did not show
        // it. Without the smoothing the Mac harness measures more colour noise on m5 (sand 0.40 -> 0.76).
        let referenceInput = image
        return colorKernel.apply(extent: image.extent, arguments: [
            image, referenceInput, CIVector(x: CGFloat(v.castGains.x), y: CGFloat(v.castGains.y), z: CGFloat(v.castGains.z), w: 0),
            CIVector(x: CGFloat(v.waterTone.x), y: CGFloat(v.waterTone.y), z: CGFloat(v.waterTone.z), w: CGFloat(v.waterRedness)),
            CIVector(x: CGFloat(v.waterSaturation), y: CGFloat(v.waterChroma), z: CGFloat(v.redCeiling), w: CGFloat(v.violetGuard)),
            CIVector(x: CGFloat(v.redRebuild), y: CGFloat(v.redGateLow), z: CGFloat(v.redGateHigh), w: CGFloat(v.subjectRed)),
            CIVector(x: CGFloat(v.toneCurve), y: CGFloat(v.tonePivot), z: CGFloat(v.midLift), w: CGFloat(v.brightness + (1 - v.contrast) * 0.5)),
            CIVector(x: CGFloat(v.neutralGains.x), y: CGFloat(v.neutralGains.y), z: CGFloat(v.neutralGains.z), w: CGFloat(v.contrast)),
            CIVector(x: CGFloat(v.waterLit.x), y: CGFloat(v.waterLit.y), z: CGFloat(v.waterLit.z), w: CGFloat(v.lightGradient)),
            CIVector(x: CGFloat(v.subjectTone.x), y: CGFloat(v.subjectTone.y), z: CGFloat(v.subjectTone.z), w: 0),
            CIVector(x: CGFloat(v.referenceGains.x), y: CGFloat(v.referenceGains.y), z: CGFloat(v.referenceGains.z), w: CGFloat(v.referenceStrength))
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
        var colors: [SIMD3<Float>] = []
        var lit: Float = 0, high: Float = 0, litLuminance: [Float] = []
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = pixels[i], g = pixels[i+1], b = pixels[i+2]
            let l = r * 0.2126 + g * 0.7152 + b * 0.0722
            // Bright share counts clipped pixels too: a blown white belly is a bright area.
            if l.isFinite, l > 0.015 { lit += 1; litLuminance.append(l); if l >= 0.35 { high += 1 } }
            guard l.isFinite, l > 0.015, l < 0.85 else { continue }
            red += max(0, r); green += max(0, g); blue += max(0, b); luminance.append(l)
            colors.append(SIMD3(max(0, r), max(0, g), max(0, b)))
            let top = max(r, g, b)
            saturation += top > 0 ? (top - min(r, g, b)) / top : 0
        }
        guard !luminance.isEmpty else { return .neutral }
        luminance.sort()
        let n = Float(luminance.count)
        let surviving = max(0.001, (green + blue) / 2)
        let loss = max(0, min(1, 1 - red / surviving))
        // Open water is the least red part of an underwater scene; subjects are redder.
        colors.sort { $0.x / max(1e-4, $0.y + $0.z) < $1.x / max(1e-4, $1.y + $1.z) }
        let waterCount = max(1, colors.count / 3)
        let water = colors.prefix(waterCount).reduce(SIMD3<Float>(repeating: 0), +) / Float(waterCount)
        // White reference candidates: outside the least red third (so not open water), among the
        // brightest fifth, clearly brighter than the water and no more colourful than it.
        let waterChroma = ColorCorrection.oklch(water).y, waterLuminance = (water * ColorCorrection.luma).sum()
        let brightCut = max(luminance[min(luminance.count - 1, luminance.count * 8 / 10)], waterLuminance * 1.25)
        var neutral = SIMD3<Float>(repeating: 0), neutralCount: Float = 0
        for c in colors.dropFirst(waterCount) where (c * ColorCorrection.luma).sum() >= brightCut
            && ColorCorrection.oklch(c).y <= min(0.2, waterChroma * 1.1) {
            neutral += c; neutralCount += 1
        }
        if neutralCount > 0 { neutral /= neutralCount }
        return WaterAnalysis(redLoss: loss, cyanDominance: max(0, min(1, (surviving - red) / surviving)),
            exposure: min(0.12, max(0, (0.22 - luminance[luminance.count/2]) * 0.6)),
            contrast: luminance[luminance.count * 9 / 10] - luminance[luminance.count / 10], saturation: saturation / n,
            meanRed: red / n, meanGreen: green / n, meanBlue: blue / n, midLuminance: luminance[luminance.count / 2],
            waterRed: water.x, waterGreen: water.y, waterBlue: water.z,
            neutralRed: neutral.x, neutralGreen: neutral.y, neutralBlue: neutral.z, neutralShare: neutralCount / n,
            highShare: lit > 0 ? high / lit : 0,
            lightShare: lit > 0 ? Float(litLuminance.filter { $0 >= waterLuminance * WaterAnalysis.lightShareRatio }.count) / lit : 0)
    }
}
