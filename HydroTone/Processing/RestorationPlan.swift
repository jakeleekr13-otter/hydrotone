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
    var depth: NormalizedDepthMap
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
    var limits: RestorationLimits
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

extension RestorationPlan {
    /// One scene plan from the kept sample plans: the mean of every scene-level value and one
    /// constant depth (the mean of the per-plan median depths). Use the same kept indices as
    /// WaterAnalysis.sceneMean, from WaterAnalysis.sceneInliers. Invalid indices are ignored;
    /// none left means all plans.
    static func sceneAverage(_ plans: [RestorationPlan], keeping: [Int]) throws -> RestorationPlan {
        let valid = keeping.filter { plans.indices.contains($0) }
        let chosen = (valid.isEmpty ? Array(plans.indices) : valid).map { plans[$0] }
        guard let first = chosen.first else { throw RestorationError.waterModelFitFailed }
        let count = Float(chosen.count)
        func mean(_ key: (RestorationPlan) -> Float) -> Float { chosen.reduce(Float(0)) { $0 + key($1) } / count }
        func mean(_ key: (RestorationPlan) -> SIMD3<Float>) -> SIMD3<Float> {
            chosen.reduce(SIMD3<Float>(repeating: 0)) { $0 + key($1) } / count
        }
        let depth = mean { plan in
            let sorted = plan.depth.values.sorted()
            return sorted.isEmpty ? 0.5 : sorted[sorted.count / 2]
        }
        let map = try NormalizedDepthMap(width: first.depth.width, height: first.depth.height,
                                         values: [Float](repeating: min(1, max(0, depth)), count: first.depth.width * first.depth.height))
        let limits = RestorationLimits(transmissionFloor: mean { $0.limits.transmissionFloor },
                                       maximumGain: mean { $0.limits.maximumGain },
                                       highlightStart: mean { $0.limits.highlightStart },
                                       highlightEnd: mean { $0.limits.highlightEnd },
                                       maximumOutput: mean { $0.limits.maximumOutput })
        return RestorationPlan(depth: map, depthSource: first.depthSource,
                               depthStatistics: DepthStatistics(minimum: mean { $0.depthStatistics.minimum },
                                                                maximum: mean { $0.depthStatistics.maximum },
                                                                median: mean { $0.depthStatistics.median }),
                               backscatterInfinity: mean { $0.backscatterInfinity }, betaDirect: mean { $0.betaDirect },
                               betaBackscatter: mean { $0.betaBackscatter }, confidence: mean { $0.confidence },
                               limits: limits, transmissionFloorPixelPercentage: mean { $0.transmissionFloorPixelPercentage },
                               maximumGainPixelPercentage: mean { $0.maximumGainPixelPercentage },
                               depthConfidence: mean { $0.depthConfidence }, waterFitConfidence: mean { $0.waterFitConfidence },
                               temporalConfidence: mean { $0.temporalConfidence },
                               channelRecoverability: mean { $0.channelRecoverability })
    }
}
