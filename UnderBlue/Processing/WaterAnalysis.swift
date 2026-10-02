import simd

struct WaterAnalysis: Sendable, Equatable {
    var redLoss: Float = 0
    var cyanDominance: Float = 0
    var exposure: Float = 0
    var contrast: Float = 0
    var saturation: Float = 0
    // Scene mean colour (linear) and median luminance. Zero means stay neutral: no cast step.
    var meanRed: Float = 0
    var meanGreen: Float = 0
    var meanBlue: Float = 0
    var midLuminance: Float = 0.18
    // Mean colour (linear) of the least red third of the scene, which is mostly open water.
    // Zero means unknown: the scene mean stands in.
    var waterRed: Float = 0
    var waterGreen: Float = 0
    var waterBlue: Float = 0
    /// Mean colour (linear) of bright, non-water pixels that are no more colourful than the water:
    /// sand, rock, a white belly. They should be near-neutral. Zero means none were found.
    var neutralRed: Float = 0
    var neutralGreen: Float = 0
    var neutralBlue: Float = 0
    /// Share of analysed pixels behind that colour: the evidence for a white reference.
    var neutralShare: Float = 0
    /// Share of lit pixels (clipped ones included) at or above luminance 0.35, about L* 66.
    /// A large bright subject in a darker scene gets less mid-tone lift and brightness.
    var highShare: Float = 0
    /// Share of lit pixels at or above lightShareRatio times the water's luminance: a strong light
    /// source (sun rays under the surface). A pale subject stays below it (2 Oct 2026, source photos:
    /// IMG_7400 light 3.5%; O1 to O5, IMG_7401 and m5 at most 1.0%). See ColorCorrection.lightGradient.
    var lightShare: Float = 0
    static let lightShareRatio: Float = 4
    /// Green over blue in the scene mean. Above one the water reads green, not blue.
    var greenOverBlue: Float { meanBlue > 0.001 && meanGreen > 0.001 ? meanGreen / meanBlue : 1 }
    var meanColor: SIMD3<Float> { SIMD3(meanRed, meanGreen, meanBlue) }
    var neutralColor: SIMD3<Float> { SIMD3(neutralRed, neutralGreen, neutralBlue) }
    var waterColor: SIMD3<Float> {
        let water = SIMD3(waterRed, waterGreen, waterBlue)
        return water.max() > 0.001 && water.x.isFinite && water.y.isFinite && water.z.isFinite ? water : meanColor
    }
    /// 0 for a neutral scene mean, 1 for a clear water cast. Neutral scenes keep their greys neutral.
    var castStrength: Float {
        let mean = meanColor, peak = mean.max()
        let chroma = peak > 0.001 ? (peak - mean.min()) / peak : 0
        return chroma.isFinite ? min(1, max(0, (chroma - 0.05) / 0.2)) : 0
    }
    static let neutral = WaterAnalysis()
    /// Every stored value. median and sceneMean walk this list, so a new field must be added
    /// here or video silently gets its default.
    static var fields: [WritableKeyPath<Self, Float>] { sceneFields + [\.neutralRed, \.neutralGreen, \.neutralBlue, \.neutralShare, \.highShare, \.lightShare] }
    /// The values that describe the water scene. sceneInliers judges frames by these only. A white
    /// surface or a bright subject comes and goes within one dive, so a frame without one is not odd.
    static var sceneFields: [WritableKeyPath<Self, Float>] { [\.redLoss, \.cyanDominance, \.exposure, \.contrast, \.saturation,
                                                             \.meanRed, \.meanGreen, \.meanBlue, \.midLuminance,
                                                             \.waterRed, \.waterGreen, \.waterBlue] }
    static func median(_ samples: [Self]) -> Self {
        guard !samples.isEmpty else { return .neutral }
        var result = Self()
        for key in fields { result[keyPath: key] = samples.map { $0[keyPath: key] }.sorted()[samples.count / 2] }
        return result
    }
    /// Indices of the samples that describe the same scene. A sample is dropped whole when any
    /// scene field sits far from the other samples (an above-water or surface frame is odd in every
    /// field). Score = largest |value - median| / max(MAD, floor). At least half always stay.
    static func sceneInliers(_ samples: [Self], threshold: Float = 4, floor: Float = 0.02) -> [Int] {
        guard samples.count >= 3 else { return Array(samples.indices) }
        func middle(_ values: [Float]) -> Float {
            let sorted = values.sorted(), half = sorted.count / 2
            return sorted.count % 2 == 1 ? sorted[half] : (sorted[half - 1] + sorted[half]) / 2
        }
        var scores = [Float](repeating: 0, count: samples.count)
        for key in sceneFields {
            let values = samples.map { $0[keyPath: key].isFinite ? $0[keyPath: key] : 0 }
            let center = middle(values)
            let spread = max(middle(values.map { abs($0 - center) }), floor)
            for index in values.indices { scores[index] = max(scores[index], abs(values[index] - center) / spread) }
        }
        let kept = samples.indices.filter { scores[$0] <= threshold }
        let minimum = (samples.count + 1) / 2
        guard kept.count < minimum else { return kept }
        // Too many odd samples means the clip itself varies. Keep the most typical half.
        return samples.indices.sorted { (scores[$0], $0) < (scores[$1], $1) }.prefix(minimum).sorted()
    }
    /// Mean of the kept samples. Out-of-range indices are ignored; none left means all samples.
    static func sceneMean(_ samples: [Self], keeping: [Int]) -> Self {
        let valid = keeping.filter { samples.indices.contains($0) }
        let chosen = valid.isEmpty ? Array(samples.indices) : valid
        guard !chosen.isEmpty else { return .neutral }
        var result = Self()
        for key in fields {
            result[keyPath: key] = chosen.reduce(Float(0)) { $0 + (samples[$1][keyPath: key].isFinite ? samples[$1][keyPath: key] : 0) } / Float(chosen.count)
        }
        // The white surface colour comes only from frames that found one, weighted by their evidence.
        // Zeros from the other frames would darken it. neutralShare stays the plain mean, so a
        // surface seen in few frames counts for less.
        var neutral = SIMD3<Float>(repeating: 0), total: Float = 0
        for index in chosen {
            let c = samples[index].neutralColor, weight = samples[index].neutralShare
            guard weight.isFinite, weight > 0, c.x.isFinite, c.y.isFinite, c.z.isFinite else { continue }
            neutral += c * weight; total += weight
        }
        if total > 0 { neutral /= total }
        result.neutralRed = neutral.x; result.neutralGreen = neutral.y; result.neutralBlue = neutral.z
        return result
    }
}
