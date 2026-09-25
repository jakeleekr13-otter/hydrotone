import AVFoundation
import CoreImage
import CoreML
import ImageIO
import Metal
import os

actor DepthEstimator {
    static let modelSize = CGSize(width: 518, height: 392)

    private let context: CIContext
    private let computeUnits: MLComputeUnits
    private let modelStore: DepthModelStore
    #if DEBUG
    private let logger = Logger(subsystem: "com.hydrotone.app", category: "photo-depth")
    #endif

    init(computeUnits: MLComputeUnits = .all, modelStore: DepthModelStore = .shared) {
        self.computeUnits = computeUnits
        self.modelStore = modelStore
        let options: [CIContextOption: Any] = [.cacheIntermediates: false]
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            context = CIContext(options: options)
        }
    }

    func estimate(image: CIImage, sourceURL: URL) async throws -> DepthEstimate {
        try Task.checkCancellation()
        if let embedded = try embeddedDepth(from: sourceURL) {
            log(embedded)
            return embedded
        }
        let result = try await monocularDepth(for: image)
        log(result)
        return result
    }

    /// Internal so the model integration can be exercised without constructing a photo container.
    func monocularDepth(for image: CIImage) async throws -> DepthEstimate {
        guard !image.extent.isEmpty else { throw RestorationError.invalidDepth }
        let input = try makePixelBuffer(width: Int(Self.modelSize.width), height: Int(Self.modelSize.height),
                                        pixelFormat: kCVPixelFormatType_32ARGB)
        let translated = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let resized = translated.transformed(by: CGAffineTransform(
            scaleX: Self.modelSize.width / image.extent.width,
            y: Self.modelSize.height / image.extent.height))
        context.render(resized, to: input, bounds: CGRect(origin: .zero, size: Self.modelSize),
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))

        let (samples, milliseconds) = try await modelStore.depth(from: input, computeUnits: computeUnits)
        // Depth Anything V2's relative output is inverse-depth-like: larger values are nearer.
        return try normalize(samples, source: .monocular, fartherIsLarger: false,
                             baseConfidence: 0.72, inferenceMilliseconds: milliseconds)
    }

    private func embeddedDepth(from url: URL) throws -> DepthEstimate? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let rawOrientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up
        for type in [kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity] {
            guard let dictionary = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) as? [AnyHashable: Any] else { continue }
            let depth = try AVDepthData(fromDictionaryRepresentation: dictionary)
                .applyingExifOrientation(orientation)
            let converted: AVDepthData
            if depth.availableDepthDataTypes.contains(kCVPixelFormatType_DepthFloat32) {
                converted = depth.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
            } else {
                converted = depth
            }
            let reduced = try reducedDepthBuffer(converted.depthDataMap)
            return try normalize(DepthSamples(reduced), source: .embedded, fartherIsLarger: converted.depthDataType == kCVPixelFormatType_DepthFloat16 || converted.depthDataType == kCVPixelFormatType_DepthFloat32,
                                 baseConfidence: converted.depthDataAccuracy == .absolute ? 0.96 : 0.88,
                                 inferenceMilliseconds: nil)
        }
        return nil
    }

    private func reducedDepthBuffer(_ buffer: CVPixelBuffer) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let scale = min(1, 518 / Double(max(width, height)))
        guard scale < 1 else { return buffer }
        let targetWidth = max(2, Int(Double(width) * scale))
        let targetHeight = max(2, Int(Double(height) * scale))
        let destination = try makePixelBuffer(width: targetWidth, height: targetHeight,
                                              pixelFormat: kCVPixelFormatType_DepthFloat32)
        let image = CIImage(cvPixelBuffer: buffer).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        context.render(image, to: destination, bounds: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight), colorSpace: nil)
        return destination
    }

    private func normalize(_ samples: DepthSamples, source: DepthSource, fartherIsLarger: Bool,
                           baseConfidence: Float, inferenceMilliseconds: Double?) throws -> DepthEstimate {
        let width = samples.width, height = samples.height
        let raw = samples.values
        let finite = raw.filter { $0.isFinite && (source == .monocular || $0 > 0) }.sorted()
        guard finite.count >= max(16, raw.count / 3) else { throw RestorationError.invalidDepth }
        let minimum = finite.first!, maximum = finite.last!
        let median = percentile(finite, 0.5)
        let low = percentile(finite, 0.05), high = percentile(finite, 0.95)
        let range = high - low
        guard range.isFinite, range > max(1e-6, abs(median) * 1e-5) else {
            throw RestorationError.insufficientDepthVariation
        }
        let replacement = fartherIsLarger ? (median - low) / range : 1 - (median - low) / range
        let normalized = raw.map { value -> Float in
            guard value.isFinite, source == .monocular || value > 0 else { return min(1, max(0, replacement)) }
            let unit = min(1, max(0, (value - low) / range))
            return fartherIsLarger ? unit : 1 - unit
        }
        let finiteFraction = Float(finite.count) / Float(raw.count)
        let clipped = Float(raw.reduce(0) { count, value in
            guard value.isFinite else { return count + 1 }
            return count + ((value <= low || value >= high) ? 1 : 0)
        }) / Float(raw.count)
        let confidence = min(1, max(0, baseConfidence * finiteFraction * (1 - min(0.45, clipped * 0.35))))
        return DepthEstimate(map: try NormalizedDepthMap(width: width, height: height, values: normalized),
                             source: source, statistics: .init(minimum: minimum, maximum: maximum, median: median),
                             confidence: confidence, inferenceMilliseconds: inferenceMilliseconds)
    }

    private nonisolated func makePixelBuffer(width: Int, height: Int, pixelFormat: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw RestorationError.invalidDepth }
        return buffer
    }

    private func percentile(_ sorted: [Float], _ fraction: Float) -> Float {
        sorted[min(sorted.count - 1, max(0, Int(Float(sorted.count - 1) * fraction)))]
    }

    private func log(_ estimate: DepthEstimate) {
        #if DEBUG
        let timing = estimate.inferenceMilliseconds.map { String(format: "%.2fms", $0) } ?? "embedded"
        logger.debug("source=\(estimate.source.rawValue, privacy: .public) inference=\(timing, privacy: .public) min=\(estimate.statistics.minimum) max=\(estimate.statistics.maximum) median=\(estimate.statistics.median) confidence=\(estimate.confidence)")
        #endif
    }
}

actor DepthModelStore {
    static let shared = DepthModelStore()
    private var allModel: MLModel?
    private var neuralEngineModel: MLModel?

    /// Runs inference here so the non-Sendable model never leaves this actor; only Sendable samples do.
    func depth(from input: sending CVPixelBuffer,
               computeUnits: MLComputeUnits) async throws -> (samples: DepthSamples, milliseconds: Double) {
        let loaded = try await model(computeUnits: computeUnits)
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)])
        let start = ContinuousClock.now
        let prediction = try predict(loaded, provider)
        let elapsed = ContinuousClock.now - start
        guard let buffer = prediction.featureValue(for: "depth")?.imageBufferValue else {
            throw RestorationError.invalidDepth
        }
        let milliseconds = elapsed.components.seconds.doubleValue * 1_000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        return (try DepthSamples(buffer), milliseconds)
    }

    /// Synchronous on purpose: the async overload is @concurrent and would send the model off this actor.
    private func predict(_ model: MLModel, _ provider: MLFeatureProvider) throws -> MLFeatureProvider {
        try model.prediction(from: provider)
    }

    private func model(computeUnits: MLComputeUnits) async throws -> MLModel {
        if computeUnits == .cpuAndNeuralEngine, let neuralEngineModel { return neuralEngineModel }
        if computeUnits != .cpuAndNeuralEngine, let allModel { return allModel }
        let bundles = [Bundle(for: ModelBundleToken.self), .main]
        guard let url = bundles.compactMap({ $0.url(forResource: "DepthAnythingV2SmallF16P6", withExtension: "mlmodelc") }).first else {
            throw RestorationError.missingModel
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let loaded = try await MLModel.load(contentsOf: url, configuration: configuration)
        if computeUnits == .cpuAndNeuralEngine { neuralEngineModel = loaded }
        else { allModel = loaded }
        return loaded
    }
}

/// Single-channel depth copied out of a pixel buffer, so it can cross actor boundaries.
struct DepthSamples: Sendable {
    let width: Int
    let height: Int
    let values: [Float]

    init(_ buffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw RestorationError.invalidDepth }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        var result = [Float](repeating: .nan, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow)
            switch format {
            case kCVPixelFormatType_OneComponent16Half, kCVPixelFormatType_DepthFloat16, kCVPixelFormatType_DisparityFloat16:
                let values = row.assumingMemoryBound(to: UInt16.self)
                for x in 0..<width { result[y * width + x] = Float(Float16(bitPattern: values[x])) }
            case kCVPixelFormatType_DepthFloat32, kCVPixelFormatType_DisparityFloat32, kCVPixelFormatType_OneComponent32Float:
                let values = row.assumingMemoryBound(to: Float.self)
                for x in 0..<width { result[y * width + x] = values[x] }
            default:
                throw RestorationError.invalidDepth
            }
        }
        self.width = width
        self.height = height
        self.values = result
    }
}

private final class ModelBundleToken { }

private extension Int64 {
    var doubleValue: Double { Double(self) }
}
