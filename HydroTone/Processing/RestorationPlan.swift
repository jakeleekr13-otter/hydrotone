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
    let limits: RestorationLimits
    let transmissionFloorPixelPercentage: Float
    let maximumGainPixelPercentage: Float
}

enum RestorationError: Error {
    case missingModel
    case invalidDepth
    case insufficientDepthVariation
    case waterModelFitFailed
    case kernelUnavailable
}

