import CoreImage
import CoreImage.CIFilterBuiltins
import Metal

// Immutable settings are shared by preview and export. Analysis never changes per video frame.
enum DivePreset: String, CaseIterable, Identifiable, Sendable {
    case original = "Original", natural = "Natural Dive", red = "Restore Red"
    case clear = "Clear Water", tropical = "Tropical", deep = "Deep Dive"
    var id: String { rawValue }
    var localizedName: String { String(localized: String.LocalizationValue(rawValue)) }
    var restoration: Float {
        switch self { case .original: 0; case .natural: 0.45; case .red: 0.72; case .clear: 0.36; case .tropical: 0.42; case .deep: 0.82 }
    }
    var vibrance: Float {
        switch self { case .original: 0; case .natural: 0.10; case .red: 0.06; case .clear: 0.13; case .tropical: 0.22; case .deep: 0.10 }
    }
}
struct WaterAnalysis: Sendable, Equatable {
    var redLoss: Float = 0
    var cyanDominance: Float = 0
    var exposure: Float = 0
    var contrast: Float = 0
    var saturation: Float = 0
    static let neutral = WaterAnalysis()
    static func median(_ samples: [Self]) -> Self {
        guard !samples.isEmpty else { return .neutral }
        func mid(_ key: KeyPath<Self, Float>) -> Float {
            let values = samples.map { $0[keyPath: key] }.sorted()
            return values[values.count / 2]
        }
        return Self(redLoss: mid(\.redLoss), cyanDominance: mid(\.cyanDominance), exposure: mid(\.exposure), contrast: mid(\.contrast), saturation: mid(\.saturation))
    }
}
struct FilterSettings: Sendable, Equatable {
    var preset: DivePreset = .natural
    var intensity: Float = 0.8
    var analysis: WaterAnalysis = .neutral
}

final class FilterEngine: @unchecked Sendable {
    // CIContext is thread safe. CIFilters are local to each invocation.
    let context: CIContext
    static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    static let photoSpace = CGColorSpace(name: CGColorSpace.displayP3)!
    init() {
        let options: [CIContextOption: Any] = [.workingColorSpace: Self.workingSpace, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false]
        if let device = MTLCreateSystemDefaultDevice() { context = CIContext(mtlDevice: device, options: options) }
        else { context = CIContext(options: options) }
    }
    func apply(_ image: CIImage, settings: FilterSettings) -> CIImage {
        let amount = min(1, max(0, settings.intensity))
        guard settings.preset != .original, amount > 0 else { return image }
        return blend(image, finishing(image, settings: settings), amount: amount)
    }
    /// Applies a preset at full strength. Callers choose what the final intensity blends against.
    func finishing(_ image: CIImage, settings: FilterSettings) -> CIImage {
        guard settings.preset != .original else { return image }
        let analysis = settings.analysis
        let restore = CGFloat(settings.preset.restoration * min(0.9, max(0, analysis.redLoss)))
        // Convex channel reconstruction protects neutral whites and avoids amplifying red noise.
        // Retain most of the source red; mix in a bounded estimate from surviving wavelengths.
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = CIVector(x: 1 - restore, y: restore * 0.72, z: restore * 0.28, w: 0)
        let cyan = CGFloat(analysis.cyanDominance) * 0.025
        matrix.gVector = CIVector(x: cyan, y: 1 - cyan, z: 0, w: 0)
        matrix.bVector = CIVector(x: cyan, y: 0, z: 1 - cyan, w: 0)
        var corrected = matrix.outputImage ?? image
        if settings.preset == .tropical {
            let warmth = CIFilter.temperatureAndTint()
            warmth.inputImage = corrected
            warmth.neutral = CIVector(x: 6500, y: 0)
            warmth.targetNeutral = CIVector(x: 6800, y: 0)
            corrected = warmth.outputImage ?? corrected
        }
        let vibrance = CIFilter.vibrance()
        vibrance.inputImage = corrected
        vibrance.amount = settings.preset.vibrance * max(0.3, 1 - analysis.saturation)
        corrected = vibrance.outputImage ?? corrected
        if settings.preset == .clear {
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = corrected
            exposure.ev = min(0.12, max(0, analysis.exposure))
            corrected = exposure.outputImage ?? corrected
        }
        return corrected.cropped(to: image.extent)
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
            contrast: luminance[luminance.count * 9 / 10] - luminance[luminance.count / 10], saturation: saturation / n)
    }
}
