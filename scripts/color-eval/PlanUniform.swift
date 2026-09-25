// Harness-only helper. Mirrors the video path: one scene-level plan with a constant (median) depth.
// If you add stored properties to RestorationPlan, carry them over here too.
extension RestorationPlan {
    func withUniformDepth() throws -> RestorationPlan {
        let sorted = depth.values.sorted()
        let median = sorted[sorted.count / 2]
        let map = try NormalizedDepthMap(width: depth.width, height: depth.height,
                                         values: [Float](repeating: median, count: depth.values.count))
        return RestorationPlan(depth: map, depthSource: depthSource, depthStatistics: depthStatistics,
                               backscatterInfinity: backscatterInfinity, betaDirect: betaDirect,
                               betaBackscatter: betaBackscatter, confidence: confidence, limits: limits,
                               transmissionFloorPixelPercentage: transmissionFloorPixelPercentage,
                               maximumGainPixelPercentage: maximumGainPixelPercentage,
                               depthConfidence: depthConfidence, waterFitConfidence: waterFitConfidence,
                               temporalConfidence: temporalConfidence, channelRecoverability: channelRecoverability)
    }
}
