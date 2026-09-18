import Foundation

enum DepthSource: String, Sendable {
    case embedded
    case monocular
}

struct DepthStatistics: Sendable, Equatable {
    let minimum: Float
    let maximum: Float
    let median: Float
}

/// A compact, normalized distance map. Zero is near and one is far.
/// Values stay at analysis resolution; Core Image scales them only while rendering.
struct NormalizedDepthMap: Sendable, Equatable {
    let width: Int
    let height: Int
    let values: [Float]

    init(width: Int, height: Int, values: [Float]) throws {
        guard width > 1, height > 1, values.count == width * height,
              values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
            throw RestorationError.invalidDepth
        }
        self.width = width
        self.height = height
        self.values = values
    }
}

struct DepthEstimate: Sendable, Equatable {
    let map: NormalizedDepthMap
    let source: DepthSource
    let statistics: DepthStatistics
    let confidence: Float
    let inferenceMilliseconds: Double?

    func resampled(maxDimension: Int) throws -> Self {
        let source = map
        guard max(source.width, source.height) > maxDimension else { return self }
        let scale = Float(maxDimension) / Float(max(source.width, source.height))
        let width = max(2, Int(Float(source.width) * scale))
        let height = max(2, Int(Float(source.height) * scale))
        var output = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let sourceY = Float(y) * Float(source.height - 1) / Float(max(1, height - 1))
            let y0 = Int(sourceY), y1 = min(source.height - 1, y0 + 1), fy = sourceY - Float(y0)
            for x in 0..<width {
                let sourceX = Float(x) * Float(source.width - 1) / Float(max(1, width - 1))
                let x0 = Int(sourceX), x1 = min(source.width - 1, x0 + 1), fx = sourceX - Float(x0)
                let top = source.values[y0 * source.width + x0] * (1 - fx) + source.values[y0 * source.width + x1] * fx
                let bottom = source.values[y1 * source.width + x0] * (1 - fx) + source.values[y1 * source.width + x1] * fx
                output[y * width + x] = min(1, max(0, top * (1 - fy) + bottom * fy))
            }
        }
        return Self(map: try NormalizedDepthMap(width: width, height: height, values: output), source: self.source,
                    statistics: statistics, confidence: confidence, inferenceMilliseconds: inferenceMilliseconds)
    }
}

struct RestorationLimits: Sendable, Equatable {
    var transmissionFloor: Float = 0.28
    var maximumGain = SIMD3<Float>(1.65, 1.55, 1.45)
    var highlightStart: Float = 0.72
    var highlightEnd: Float = 1.0
    var maximumOutput: Float = 1.15
}

struct RestorationPlan: Sendable, Equatable {
    let depth: NormalizedDepthMap
    let depthSource: DepthSource
    let depthStatistics: DepthStatistics
    let backscatterInfinity: SIMD3<Float>
    let betaDirect: SIMD3<Float>
    let betaBackscatter: SIMD3<Float>
    let confidence: Float
    let depthConfidence: Float
    let waterFitConfidence: Float
    let temporalConfidence: Float
    let channelRecoverability: SIMD3<Float>
    let limits: RestorationLimits
    let transmissionFloorPixelPercentage: Float
    let maximumGainPixelPercentage: Float

    init(depth: NormalizedDepthMap, depthSource: DepthSource, depthStatistics: DepthStatistics,
         backscatterInfinity: SIMD3<Float>, betaDirect: SIMD3<Float>, betaBackscatter: SIMD3<Float>,
         confidence: Float, limits: RestorationLimits, transmissionFloorPixelPercentage: Float,
         maximumGainPixelPercentage: Float, depthConfidence: Float? = nil,
         waterFitConfidence: Float? = nil, temporalConfidence: Float = 1,
         channelRecoverability: SIMD3<Float> = .init(repeating: 1)) {
        func unit(_ value: Float) -> Float { value.isFinite ? min(1, max(0, value)) : 0 }
        self.depth = depth
        self.depthSource = depthSource
        self.depthStatistics = depthStatistics
        self.backscatterInfinity = backscatterInfinity
        self.betaDirect = betaDirect
        self.betaBackscatter = betaBackscatter
        self.depthConfidence = unit(depthConfidence ?? confidence)
        self.waterFitConfidence = unit(waterFitConfidence ?? confidence)
        self.temporalConfidence = unit(temporalConfidence)
        self.channelRecoverability = SIMD3(unit(channelRecoverability.x), unit(channelRecoverability.y), unit(channelRecoverability.z))
        // A critical failure gates the physical contribution; unrelated high values cannot hide it.
        self.confidence = min(unit(confidence), self.depthConfidence, self.waterFitConfidence, self.temporalConfidence)
        self.limits = limits
        self.transmissionFloorPixelPercentage = transmissionFloorPixelPercentage.isFinite ? transmissionFloorPixelPercentage : 0
        self.maximumGainPixelPercentage = maximumGainPixelPercentage.isFinite ? maximumGainPixelPercentage : 0
    }

    var effectiveChannelWeights: SIMD3<Float> { channelRecoverability * confidence }
}

enum RestorationError: Error {
    case missingModel
    case invalidDepth
    case insufficientDepthVariation
    case waterModelFitFailed
    case kernelUnavailable
}
