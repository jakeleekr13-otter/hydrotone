import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import simd

// Immutable settings are shared by preview and export. Analysis never changes per video frame.
enum DivePreset: String, CaseIterable, Identifiable, Sendable {
    case original = "Original", natural = "Natural Dive"
    case tropical = "Tropical", deep = "Deep Dive"
    /// The user preset: the automatic (Natural) result plus the user's CustomAdjustments, at full strength.
    case custom = "Custom"
    var id: String { rawValue }
    var localizedName: String { String(localized: String.LocalizationValue(rawValue)) }
    var restoration: Float {
        switch self { case .original: 0; case .natural, .custom: 0.45; case .tropical: 0.50; case .deep: 0.56 }
    }
    var vibrance: Float {
        switch self { case .original: 0; case .natural, .custom: 0.18; case .tropical: 0.22; case .deep: 0.18 }
    }
    var castRemoval: Float {
        switch self { case .original: 0; case .natural, .custom: 0.16; case .tropical: 0.16; case .deep: 0.18 }
    }
    var contrast: Float {
        switch self { case .original: 1; case .natural, .custom: 1.04; case .tropical: 1.04; case .deep: 1.04 }
    }
    var saturation: Float {
        switch self { case .original: 1; case .natural, .custom: 1.08; case .tropical: 1.16; case .deep: 1.08 }
    }
    var clarity: Float {
        switch self { case .original: 0; case .natural, .custom: 0.16; case .tropical: 0.19; case .deep: 0.25 }
    }
    /// Colour temperature shift in kelvin for an underwater scene. A grey scene (scene-mean chroma
    /// 0.05 or less) gets none; the full shift applies from chroma 0.10.
    var warmth: Float {
        switch self { case .original, .natural, .deep, .custom: 0; case .tropical: 600 }
    }
    /// Scale on the water tone's chroma ceiling: below 1 calms neon water. The water tone holds the
    /// water's hue, so calmer water does not drift toward violet. (Scaling waterSaturation instead
    /// turned pale blue water lavender.)
    var waterChroma: Float {
        switch self { case .original, .natural, .tropical, .custom: 1; case .deep: 0.85 }
    }
    /// Extra shadow lift, added after the global contrast. Deep Dive lifts dark subjects further.
    var shadowBoost: Float {
        switch self { case .original, .natural, .tropical, .custom: 0; case .deep: 0.10 }
    }
    var symbolName: String {
        switch self {
        case .original: "circle.lefthalf.filled"
        case .natural: "water.waves"
        case .tropical: "sun.max.fill"
        case .deep: "drop.fill"
        case .custom: "gearshape"
        }
    }
}
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
    static var fields: [WritableKeyPath<Self, Float>] { sceneFields + [\.neutralRed, \.neutralGreen, \.neutralBlue, \.neutralShare, \.highShare] }
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
struct FilterSettings: Sendable, Equatable {
    var preset: DivePreset = .natural
    var intensity: Float = 0.8
    var analysis: WaterAnalysis = .neutral
    /// Used only by the Custom preset. Every other preset ignores them.
    var adjustments = CustomAdjustments()
    /// Custom has no intensity slider. It renders at this strength.
    static let customStrength: Float = 1
    /// The strength the pipelines blend with: the slider value, or customStrength for Custom.
    var appliedIntensity: Float { preset == .custom ? Self.customStrength : intensity }
}

/// The Custom preset's five sliders. Each is a position in -1...1 (shown as -100...+100).
/// Zero is the automatic result. ColorCorrection.make turns them into correction values.
struct CustomAdjustments: Sendable, Equatable {
    var brightness: Float = 0
    var contrast: Float = 0
    var saturation: Float = 0
    var clarity: Float = 0
    var temperature: Float = 0
    static let zero = Self()
    /// Change at a full slider (position -1 or +1). Provisional: these caps will be re-measured.
    enum Caps {
        static let brightnessDown: Float = 0.25     // taken from midLift
        static let brightnessUp: Float = 0.075      // added to shadowLift
        static let contrastDown: Float = 0.10       // toneCurve
        static let contrastUp: Float = 0.02
        static let saturationDown: Float = 0.45     // saturation
        static let saturationUp: Float = 0.35       // times (1 - 0.6 x neon)
        static let clarityDown: Float = 1           // relative change of clarity and definition
        static let clarityUp: Float = 0.75
        static let temperature: Float = 1500        // kelvin added to warmth
    }
    /// Every position in -1...1. A value that is not finite becomes 0.
    var clamped: Self {
        func fix(_ x: Float) -> Float { x.isFinite ? min(1, max(-1, x)) : 0 }
        return Self(brightness: fix(brightness), contrast: fix(contrast), saturation: fix(saturation),
                    clarity: fix(clarity), temperature: fix(temperature))
    }
    /// Brightness, contrast and saturation up all brighten or add colour, so their positive parts share
    /// one budget: when their sum is above one, each positive part is scaled by 1 / sum.
    var budgeted: Self {
        var v = clamped
        let sum = max(0, v.brightness) + max(0, v.contrast) + max(0, v.saturation)
        guard sum > 1 else { return v }
        for key in [\Self.brightness, \.contrast, \.saturation] where v[keyPath: key] > 0 { v[keyPath: key] /= sum }
        return v
    }
}

/// Scene-level correction values. Analysis makes them once per photo or video scene, and
/// FilterEngine only applies them, so every frame of a clip gets the same look.
struct ColorCorrection: Sendable, Equatable {
    /// Linear per-channel gains: green-to-blue cast shift plus the red boost.
    var castGains = SIMD3<Float>(repeating: 1)
    /// Red rebuilt from green, as a share of green, where a pixel's green/blue ratio is inside the gate.
    var redRebuild: Float = 0
    var redGateLow: Float = 0.55
    var redGateHigh: Float = 0.95
    /// Red/green ratio of the water after gains and water tone. Redder pixels count as subject and get more red.
    var subjectRed: Float = 1
    /// Gains toward the clear-water target, for pixels as unred (red over green plus blue) as the
    /// water. They fade out for redder pixels, so subjects are not toned.
    var waterTone = SIMD3<Float>(repeating: 1)
    var waterRedness: Float = 0
    /// Chroma scale for water-like pixels, around their luminance (below one calms neon water).
    var waterSaturation: Float = 1
    /// Normalized chroma, (max - min) / max, of the water. Pixels much greyer than the water,
    /// such as silver fish, sand or a diver, count as subject and are not toned.
    var waterChroma: Float = 0
    /// 0 = blue water, 1 = green or teal water. Continuous, so similar scenes do not jump.
    var waterType: Float = 0
    /// Rebuilt red stops at this share of green, so grey subjects stay grey and blue pixels do not turn violet.
    var redCeiling: Float = 1.05
    /// 0...1: how firmly water-like blue pixels keep red at or below green. Zero when the "water"
    /// colour is not water at all (a frame-filling magenta anemone), so it keeps its colour.
    var violetGuard: Float = 0
    /// Mid-tone lift on gamma luminance. Black and white stay fixed.
    var midLift: Float = 0
    /// S-curve strength on gamma luminance and its pivot (scene median, gamma encoded).
    var toneCurve: Float = 0
    var tonePivot: Float = 0.45
    var brightness: Float = 0
    var contrast: Float = 1
    var saturation: Float = 1
    var shadowLift: Float = 0
    var highlightAmount: Float = 1
    /// Fine clarity and broad definition (unsharp masks). Radii are shares of the short image
    /// side, so preview, export and video frames of any size look the same.
    var clarity: Float = 0
    var clarityRadius: Float = 0.011
    var definition: Float = 0
    var definitionRadius: Float = 0.04
    /// Colour temperature shift in kelvin.
    var warmth: Float = 0
    var vibrance: Float = 0
    /// Weight of the depth-aware path in RestorationEngine.combined (the plan confidence).
    var physicalWeight: Float = 0
    /// White-reference gains. They move the scene's near-neutral surfaces toward grey and act on
    /// pixels that are not water-like, so the water keeps its colour. One means no reference.
    var neutralGains = SIMD3<Float>(repeating: 1)
    /// The water colour after the cast gains. A pixel clearly brighter than it, and of another
    /// hue, is a lit subject (a pale belly can be as unred as the water) and takes the white
    /// reference in full. Brighter water of the same hue does not. Zero means no such exception.
    var waterLit = SIMD3<Float>(repeating: 0)
    static let identity = ColorCorrection()

    /// The one place that turns measurements into correction values. Pure and deterministic.
    /// Without a plan it describes the current path (the source image). With a plan it describes
    /// finishing of the restored image, which lost the veil light and so needs a mid-tone lift.
    /// `adjustments` act only for the Custom preset. They enter before the guards and the white
    /// reference that read them, so those still run on the user's result.
    static func make(analysis: WaterAnalysis, preset: DivePreset, plan: RestorationPlan? = nil,
                     adjustments: CustomAdjustments = .zero) -> Self {
        guard preset != .original else { return .identity }
        let user = preset == .custom ? adjustments.budgeted : .zero
        typealias Caps = CustomAdjustments.Caps
        var v = Self()
        // Base cast gains come from the source colour on both paths. A plan-based estimate of the
        // restored scene mean was tried and is biased: it read violet restored water as green.
        let mean = SIMD3(analysis.meanRed, analysis.meanGreen, analysis.meanBlue)
        let restore = preset.restoration * min(0.9, max(0, analysis.redLoss))
        // Low global contrast is a reliable proxy for the veil users call underwater haze.
        let haze = min(1, max(0, (0.34 - analysis.contrast) / 0.28))
        // Green water: pull the scene mean toward a blue-leaning cyan. The 0.88 green/blue
        // target is approximate, tuned by eye; below it the water already reads blue.
        // Only a coloured cast is shifted: a neutral scene (mean chroma near 0) keeps its greys neutral.
        // The shift reads the water type, so blue water under teal sand (or a teal reef) is not shifted.
        let greenBlue = analysis.greenOverBlue
        let peak = max(mean.x, mean.y, mean.z)
        let chroma = peak > 0.001 ? (peak - min(mean.x, mean.y, mean.z)) / peak : 0
        let waterCast = min(1, max(0, (chroma - 0.05) / 0.2))
        let type = waterType(analysis)
        v.waterType = type
        let shift = greenBlue > 0.88 ? pow(0.88 / greenBlue, min(1, 0.6 + preset.castRemoval * 1.5) * waterCast * type) : 1
        var gains = SIMD3<Float>(1 + restore * 0.9, max(0.65, sqrt(shift)), min(1.7, 1 / sqrt(shift)))
        // Keep the mean luminance, so this step changes colour and not exposure.
        let before = (mean * luma).sum(), after = (mean * gains * luma).sum()
        if before > 0.001, after > 0.001 { gains *= min(1.25, max(0.8, before / after)) }
        v.castGains = gains
        // Water tone: move the open water toward a clear cyan-to-blue colour with natural chroma.
        // It acts on water-like pixels only (as unred as the water), so subjects keep their red.
        // Deep, dark, hazy scenes get a bluer, more coloured floor; bright shallow water may stay cyan.
        // All hue and chroma math here is OKLab: CIELAB hue cannot tell azure from indigo.
        let deep = min(1, max(0, (0.16 - analysis.midLuminance) / 0.1))
        let water = analysis.waterColor
        // Neon water (very high source chroma) gets no extra saturation, and a little less.
        let neon = min(1, max(0, (oklch(water).y - 0.12) / 0.1))
        v.saturation = 1 + (preset.saturation + haze * 0.10 - 1) * (1 - neon) - 0.12 * neon
        // User saturation enters here, before the water chroma ceiling reads it. Neon water gets a smaller raise.
        let userSaturation = user.saturation * (user.saturation < 0 ? Caps.saturationDown : Caps.saturationUp * (1 - 0.6 * neon))
        v.saturation += userSaturation
        let seenInput = plan.map { restoredWater(water, plan: $0) } ?? water
        v.violetGuard = waterPlausibility(oklch(water))
        // The kernel judges "water-like" before the guard, so the weights use the unguarded colour.
        let lit = seenInput * gains
        let seen = Self.violetGuard(lit, input: seenInput, waterLike: 1, strength: v.violetGuard)
        // The restored path lost the veil colour with the veil, so it keeps at least part of
        // the source path's water chroma.
        let keep = plan == nil ? 0 : oklch(water * gains).y * 0.6
        // The chroma limits allow for the later steps (saturation, contrast, shadow lift), which
        // were measured to raise far-water chroma by about 1.45 times.
        // The ceiling ignores the user's saturation, so the water shows it too. Its cap and the neon scaling
        // bound it: at +1 the water gains at most about a third more chroma.
        let seenLCh = oklch(seen), later = 1.45 * max(0.5, v.saturation - userSaturation)
        // Natural Dive keeps the plain ceiling; a preset may calm neon water further (DivePreset.waterChroma).
        let ceiling = preset == .natural ? 0.1 / later : 0.1 / later * preset.waterChroma
        let target = waterTarget(seenLCh, waterType: type, murky: deep * haze, keep: keep, source: oklch(water),
                                 ceiling: ceiling, murkyFloor: 0.14 / later)
        // More chroma than the water has is only for murky water; elsewhere it would push
        // water-coloured subjects (silver fish, blue reef) away from grey and take their red.
        let tone = waterCorrection(from: seen, to: target, maximumSaturation: target.y > seenLCh.y + 0.005 ? 1.6 : 1)
        // A colourful reef can make the scene mean look neutral while the open water is clearly
        // blue, so the water's own chroma also counts. A grey scene has grey "water" and gets none.
        let cast = max(analysis.castStrength, min(1, max(0, (oklch(water).y - 0.03) / 0.05)))
        v.waterTone = SIMD3(pow(tone.gains.x, cast), pow(tone.gains.y, cast), pow(tone.gains.z, cast))
        v.waterSaturation = pow(tone.saturation, cast)
        // The restored water is only an estimate at one depth and can be purer than the real far
        // water, so the water-like test takes the wider of the estimate and the source water.
        func redness(_ c: SIMD3<Float>) -> Float { c.x / max(1e-4, c.y + c.z) }
        func chromaShare(_ c: SIMD3<Float>) -> Float { c.max() > 1e-4 ? (c.max() - c.min()) / c.max() : 0 }
        v.waterRedness = max(redness(lit), redness(water * gains))
        v.waterChroma = min(chromaShare(lit), chromaShare(water * gains))
        let toned = Self.toned(seen, gains: v.waterTone, saturation: v.waterSaturation)
        // Pixels redder than the toned water count as subject and get the most red. The water,
        // not the scene mean, is the reference: in deep blue scenes the whole reef is blue-green.
        // The restored water is only estimated (at the mean depth), so that path meets the scene mean halfway.
        let waterRed = toned.y > 1e-4 ? toned.x / toned.y : 1
        let meanRed = mean.y * gains.y > 0.001 ? mean.x * gains.x / (mean.y * gains.y) : 1
        v.subjectRed = plan == nil ? waterRed : (waterRed + meanRed) / 2
        // Rebuild red only where a pixel is clearly greener than the toned water, so the water
        // itself gets none and cannot turn pink or violet, but blue-tinted subjects still get red.
        // In blue water the gate sits 30% above the water; in teal water it stays low enough
        // for a teal-lit face or hand.
        v.redGateLow = min(0.55 + 0.25 * (1 - type), max(0.2, toned.y / max(1e-4, toned.z) * 1.3))
        v.redGateHigh = v.redGateLow + 0.4
        // Deep blue and teal water left little red to amplify, so subjects there need more rebuilt
        // red. Strongly green water keeps the smaller amount, so weed does not turn yellow.
        let teal = type * (1 - min(1, max(0, (water.y / max(1e-4, water.z) - 1) / 0.4)))
        v.redRebuild = restore * (0.72 + 0.6 * max(1 - type, teal))
        v.tonePivot = min(0.6, max(0.3, pow(max(0, analysis.midLuminance), 1 / 2.2)))
        // A bright, sunlit scene already has its contrast: a strong S-curve would crush a dark subject.
        let bright = min(1, max(0, (analysis.midLuminance - 0.25) / 0.15))
        // 0.3 keeps the curve monotonic for any pivot in 0.3...0.6.
        v.toneCurve = min(0.3, max(0, (preset.contrast - 1) * 2 + 0.12 + haze * 0.12)) * (1 - 0.5 * bright)
        v.toneCurve = min(0.3, max(0, v.toneCurve + user.contrast * (user.contrast < 0 ? Caps.contrastDown : Caps.contrastUp)))
        // Highlight rule: a large bright area (a white belly, sunlit sand; highShare 0.02 to 0.07)
        // already lights the scene. Such scenes get less brightness, haze shadow lift and mid-tone lift.
        // It fades out in dark scenes (median 0.18 down to 0.1), where a few bright spots do not light
        // the scene, and in contrasty scenes (contrast 0.35 to 0.5), whose deep shadows need the lift.
        let key = min(1, max(0, (analysis.midLuminance - 0.1) / 0.08))
        let open = 1 - min(1, max(0, (analysis.contrast - 0.35) / 0.15))
        let highlight = key * open * min(1, max(0, (analysis.highShare - 0.02) / 0.05))
        v.brightness = analysis.exposure * 0.45 * (1 - 0.5 * highlight)
        v.contrast = preset.contrast + haze * 0.05
        // Global contrast alone can bury a dark diver or reef, so lift the lower tones.
        v.shadowLift = 0.28 + haze * 0.22 * (1 - 0.6 * highlight) + bright * 0.1
        v.shadowLift += max(0, user.brightness) * Caps.brightnessUp
        v.highlightAmount = 0.92
        // Clarity restores local separation lost to backscatter without inventing texture.
        // Definition works at a broader scale, on the veil over distant water and reef.
        v.clarity = preset.clarity * (0.65 + haze * 0.35) * 1.2
        v.clarityRadius = (5 + haze * 3) / 480
        v.definition = preset.clarity * (0.5 + haze * 0.8)
        let sharpen = 1 + user.clarity * (user.clarity < 0 ? Caps.clarityDown : Caps.clarityUp)
        v.clarity *= sharpen; v.definition *= sharpen
        v.vibrance = preset.vibrance * max(0.3, 1 - analysis.saturation) * (1 - neon)
        if let plan {
            v.physicalWeight = plan.confidence
            // Give back the light the restored image lost with the veil: move its estimated
            // median luminance toward the source median times a small brightness goal, but
            // never above 0.22 (about L* 54), so bright scenes are not lifted further. The highlight
            // rule lowers that ceiling to 0.132.
            let before = (mean * luma).sum(), after = (restoredMean(mean, plan: plan) * luma).sum()
            let ratio = before > 0.001 ? min(1.5, max(0.2, after / before)) : 1
            let restoredMid = analysis.midLuminance * ratio
            // Deep, murky scenes are the darkest, so they get a larger goal.
            let murky = deep * haze
            let goal = analysis.midLuminance * (1.2 + 0.9 * murky * murky)
            let ceiling = 0.22 * (1 - 0.4 * highlight)
            v.midLift = midLift(from: restoredMid, to: min(goal, max(restoredMid, ceiling)))
        }
        if preset != .natural, preset != .custom {
            // Preset terms. Natural Dive and Custom have none: Natural's values are the base for Custom.
            v.warmth = preset.warmth * min(1, analysis.castStrength * 4)
            v.shadowLift += preset.shadowBoost
            // The preset's extra saturation is meant for subjects. Water-like pixels give it back, so they
            // keep the saturation Natural Dive gives this scene.
            let naturalSaturation = 1 + (DivePreset.natural.saturation + haze * 0.10 - 1) * (1 - neon) - 0.12 * neon
            v.waterSaturation *= naturalSaturation / max(0.5, v.saturation)
        }
        // Custom: the user's temperature on top of the automatic result (no preset warmth).
        v.warmth += user.temperature * Caps.temperature
        // Brightness down lowers the mid-tones on both paths. The white reference below sees the result.
        v.midLift = min(0.9, max(minimumMidLift, v.midLift + min(0, user.brightness) * Caps.brightnessDown))
        v.waterLit = lit
        v.neutralGains = whiteReference(analysis, correction: v, plan: plan)
        return v.sanitized()
    }

    /// White reference: gains that move the scene's near-neutral surfaces (analysis.neutralColor)
    /// toward grey, as the finishing stage sees them. On the restored path the surface is seen after
    /// veil removal (restoredMean). It acts only with enough evidence, when the surface takes the
    /// reference (FinishingMath.neutralWeight), and when what is left on it is a pale water cast.
    /// No reference, or a warm, blue or colourful one, gives gains of one: no change. The kernel
    /// applies the gains by neutralWeight, so the open water keeps its cyan-to-blue colour.
    static func whiteReference(_ analysis: WaterAnalysis, correction v: ColorCorrection, plan: RestorationPlan?) -> SIMD3<Float> {
        func smoothstep(_ low: Float, _ high: Float, _ x: Float) -> Float {
            let t = min(1, max(0, (x - low) / max(1e-5, high - low)))
            return t * t * (3 - 2 * t)
        }
        let reference = analysis.neutralColor
        guard reference.x.isFinite, reference.y.isFinite, reference.z.isFinite, reference.min() >= 0,
              (reference * luma).sum() > 0.02 else { return .one }
        // Evidence: a few pixels could be one fish; 6% of the scene is a real surface.
        let evidence = smoothstep(0.01, 0.06, analysis.neutralShare)
        guard evidence > 0 else { return .one }
        // A lit surface is usually nearer than the water, so it is restored at the depth 35% of
        // the map lies below, not at the mean depth. Constant-depth video gets its one depth.
        let seen = plan.map { p -> SIMD3<Float> in
            let sorted = p.depth.values.sorted()
            return restoredMean(reference, plan: p, depth: sorted.isEmpty ? nil : sorted[min(sorted.count - 1, sorted.count * 35 / 100)])
        } ?? reference
        var probe = v
        probe.neutralGains = .one
        let lch = oklch(FinishingMath.color(seen, correction: probe))
        // Only a pale water cast counts: OKLab hue green to cyan-blue (150 to 235), chroma below 0.10.
        // A blue remainder may be a blue subject, and a warm one is a real colour.
        let castHue = smoothstep(120, 150, lch.z) * (1 - smoothstep(235, 255, lch.z))
        let pale = 1 - smoothstep(0.10, 0.18, lch.y)
        // A strongly blue reference (blue well above green and red) looks the same as pale, bright
        // water near the surface, so it is not trusted.
        let blueLit = 1 - smoothstep(1.4, 1.8, reference.z / max(1e-4, max(reference.x, reference.y)))
        let strength = evidence * blueLit * castHue * pale * FinishingMath.neutralWeight(seen * v.castGains, correction: v)
        guard strength > 0.001 else { return .one }
        // Red may rise up to 3 times. Green never rises more than 5%: extra green turns fish lime.
        let low = SIMD3<Float>(0.5, 0.5, 0.5), high = SIMD3<Float>(3, 1.05, 1.5)
        let base = seen * pointwiseMax(v.castGains, .zero)
        func level(_ g: SIMD3<Float>) -> SIMD3<Float> {
            let bounded = pointwiseMin(high, pointwiseMax(low, g))
            let after = (base * bounded * luma).sum()
            return after > 1e-5 ? bounded * ((base * luma).sum() / after) : bounded
        }
        // Full neutral first: each channel moves toward the output luminance, a few times, because the
        // red rebuild depends on green. Then only `strength` of that step, in log space.
        var gains = SIMD3<Float>(repeating: 1)
        for _ in 0..<8 {
            probe.neutralGains = gains
            let out = FinishingMath.color(seen, correction: probe), y = (out * luma).sum()
            guard y > 1e-4, out.min() > 1e-5 else { break }
            gains = level(gains * (SIMD3(repeating: y) / out))
        }
        let partial = level(SIMD3(pow(gains.x, strength), pow(gains.y, strength), pow(gains.z, strength)))
        return partial.x.isFinite && partial.y.isFinite && partial.z.isFinite ? partial : .one
    }

    /// CIE L*a*b* (D65) of a linear Rec. 2020 colour, the working space.
    static func lab(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let x = (0.6369580 * c.x + 0.1446169 * c.y + 0.1688810 * c.z) / 0.95047
        let y = 0.2627002 * c.x + 0.6779981 * c.y + 0.0593017 * c.z
        let z = (0.0280727 * c.y + 1.0609851 * c.z) / 1.08883
        func f(_ t: Float) -> Float { t > 0.008856 ? cbrt(t) : 7.787 * max(0, t) + 16 / 116 }
        return SIMD3(116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }
    /// L*, chroma and hue angle in degrees.
    static func lightnessChromaHue(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let v = lab(c), hue = atan2(v.z, v.y) * 180 / .pi
        return SIMD3(v.x, sqrt(v.y * v.y + v.z * v.z), hue < 0 ? hue + 360 : hue)
    }

    /// OKLab (L, a, b) of a linear Rec. 2020 colour, the working space.
    static func oklab(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let x = 0.6369580 * c.x + 0.1446169 * c.y + 0.1688810 * c.z
        let y = 0.2627002 * c.x + 0.6779981 * c.y + 0.0593017 * c.z
        let z = 0.0280727 * c.y + 1.0609851 * c.z
        let l = cbrt(0.8189330101 * x + 0.3618667424 * y - 0.1288597137 * z)
        let m = cbrt(0.0329845436 * x + 0.9293118715 * y + 0.0361456387 * z)
        let s = cbrt(0.0482003018 * x + 0.2643662691 * y + 0.6338517070 * z)
        return SIMD3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                     1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                     0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }
    /// OKLab lightness, chroma and hue angle in degrees. Cyan is about 200, azure 250,
    /// pure blue 264, indigo 276 and violet 290.
    static func oklch(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let v = oklab(c), hue = atan2(v.z, v.y) * 180 / .pi
        return SIMD3(v.x, sqrt(v.y * v.y + v.z * v.z), hue < 0 ? hue + 360 : hue)
    }

    /// 0 for blue water, 1 for green or teal water, from the open-water colour. Green over blue
    /// alone misses teal (green about equal to blue), so the red the water lost counts too.
    /// A neutral scene is not water and gets 0.
    static func waterType(_ analysis: WaterAnalysis) -> Float {
        let water = analysis.waterColor
        guard water.z > 1e-4, water.y > 1e-4 else { return 0 }
        let redLoss = min(1, max(0, 1 - water.x / ((water.y + water.z) / 2)))
        let green = water.y / water.z + 0.3 * redLoss
        let type = min(1, max(0, (green - 0.6) / 0.4)) * analysis.castStrength
        return type.isFinite ? type : 0
    }

    /// 1 for an OKLCh colour open water can have (green through indigo, up to hue 285), 0 for
    /// red to yellow and for violet or magenta (hue 290 and above), with short ramps between.
    static func waterPlausibility(_ water: SIMD3<Float>) -> Float {
        let hue = water.z
        let plausible = min(1, max(0, (hue - 90) / 30)) * min(1, max(0, (290 - hue) / 5))
        return plausible.isFinite ? plausible : 0
    }

    /// In a blue pixel, red above green reads violet, so gains may not lift red past green or past
    /// the pixel's own red. In water-like pixels (weighted by `strength`) red stops at green.
    static func violetGuard(_ c: SIMD3<Float>, input: SIMD3<Float>, waterLike: Float, strength: Float) -> SIMD3<Float> {
        func smoothstep(_ low: Float, _ high: Float, _ x: Float) -> Float {
            let t = min(1, max(0, (x - low) / max(1e-5, high - low)))
            return t * t * (3 - 2 * t)
        }
        let blue = smoothstep(1.3, 2, c.z / max(max(c.x, c.y), 1e-4))
        let limit = max(input.x, c.y) + (c.y - max(input.x, c.y)) * min(1, max(0, waterLike * strength))
        var out = c
        out.x += (min(c.x, limit) - c.x) * blue
        return out
    }

    /// Clear-water target in OKLab (L, C, hue): same lightness, hue kept inside a cyan-to-blue
    /// band that never reaches indigo, chroma kept natural. Hues already inside the band are only
    /// nudged toward its middle. Green and teal water get a bluer lower edge. Near-grey water keeps
    /// its hue. Colours no open water has (red to yellow, and violet or magenta such as a large
    /// anemone) are not water, so they keep hue and chroma.
    /// `source` is the OKLCh of the untouched water colour; plausibility is judged on it, because
    /// the red boost can move restored water toward violet.
    static func waterTarget(_ water: SIMD3<Float>, waterType: Float, murky: Float, keep: Float = 0,
                            source: SIMD3<Float>? = nil, ceiling: Float = 0.07, murkyFloor: Float = 0.085) -> SIMD3<Float> {
        let low = 222 + 12 * waterType, high: Float = 262
        let inside = min(high, max(low, water.z))
        let goal = inside + (238 - inside) * 0.5
        let plausible = waterPlausibility(source ?? water)
        let hueWeight = min(1, max(0, (water.y - 0.015) / 0.025)) * plausible
        let hue = water.z + (goal - water.z) * hueWeight
        // Neon water is calmed; murky, deep water gets back some colour. The restored path keeps
        // part of the source chroma (`keep`), but never above the ceiling.
        let floor = max(murkyFloor * murky, min(keep, ceiling))
        let chroma = water.y + (max(floor, min(ceiling, water.y)) - water.y) * plausible
        return SIMD3(water.x, chroma, hue)
    }

    /// Per-channel gains plus a chroma scale (around luminance) that move `from` to the OKLab
    /// target at the same luminance. Gains stay inside 0.45...2 and the chroma scale inside
    /// 0.25...maximumSaturation (at most 1.6). A small cost on each change, and a larger one on
    /// any red loss, picks the gentlest solution.
    static func waterCorrection(from: SIMD3<Float>, to target: SIMD3<Float>,
                                maximumSaturation: Float = 1.6) -> (gains: SIMD3<Float>, saturation: Float) {
        guard from.x.isFinite, from.y.isFinite, from.z.isFinite, target.y.isFinite, target.z.isFinite else { return (.one, 1) }
        // Deep water can have almost no red; a small floor keeps the solve defined there.
        let from = pointwiseMax(from, SIMD3(repeating: 1e-3))
        let angle = target.z * .pi / 180, goal = SIMD2(target.y * cos(angle), target.y * sin(angle))
        let luminance = (from * luma).sum()
        func gains(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let raw = SIMD3(exp(p.x), exp(p.y), exp(-p.y))
            let scaled = toned(from, gains: .one, saturation: exp(p.z))
            let g = raw * luminance / max(1e-6, (scaled * raw * luma).sum())
            return SIMD3(min(2, max(0.45, g.x)), min(2, max(0.45, g.y)), min(2, max(0.45, g.z)))
        }
        func ab(_ p: SIMD3<Float>) -> SIMD2<Float> {
            let v = oklab(toned(from, gains: gains(p), saturation: exp(p.z)))
            return SIMD2(v.y, v.z)
        }
        // Cost: distance to the goal plus a small preference for the smallest change, red most.
        let weight = SIMD3<Float>(1e-4, 1e-4, 1e-4)
        let topScale = log(min(1.6, max(0.25, maximumSaturation)))
        // Taking red from water-like pixels would take it from water-coloured subjects too.
        func cost(_ p: SIMD3<Float>) -> Float {
            let redLoss = min(0, log(gains(p).x))
            return simd_length_squared(goal - ab(p)) + (weight * p * p).sum() + 0.05 * redLoss * redLoss
        }
        func bounded(_ p: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(min(0.4, max(-0.5, p.x)), min(0.7, max(-0.7, p.y)), min(topScale, max(log(0.25), p.z)))
        }
        // A coarse grid first: nearly single-channel water (green almost zero) has flat
        // directions where a local solve stalls. Then a few damped Gauss-Newton steps.
        var best = SIMD3<Float>(0, 0, 0), bestCost = cost(best)
        for x in stride(from: Float(-0.5), through: 0.4, by: 0.1) {
            for y in stride(from: Float(-0.7), through: 0.7, by: 0.14) {
                for scale: Float in [0.25, 0.35, 0.5, 0.7, 1, 1.25, 1.6] {
                    let p = bounded(SIMD3(x, y, log(scale))), c = cost(p)
                    if c < bestCost { best = p; bestCost = c }
                }
            }
        }
        for _ in 0..<8 {
            let now = ab(best), step: Float = 0.005
            let j0 = (ab(best + SIMD3(step, 0, 0)) - now) / step
            let j1 = (ab(best + SIMD3(0, step, 0)) - now) / step
            let j2 = (ab(best + SIMD3(0, 0, step)) - now) / step
            let miss = goal - now
            // (J^T J + W) dp = J^T miss - W p, a 3 x 3 system.
            let a = simd_float3x3(rows: [
                SIMD3(dot(j0, j0) + weight.x, dot(j0, j1), dot(j0, j2)),
                SIMD3(dot(j1, j0), dot(j1, j1) + weight.y, dot(j1, j2)),
                SIMD3(dot(j2, j0), dot(j2, j1), dot(j2, j2) + weight.z)])
            guard abs(a.determinant) > 1e-14 else { break }
            let move = a.inverse * (SIMD3(dot(j0, miss), dot(j1, miss), dot(j2, miss)) - weight * best)
            var length: Float = 1, improved = false
            for _ in 0..<4 where !improved {
                let p = bounded(best + move * length), c = cost(p)
                if c.isFinite, c < bestCost { best = p; bestCost = c; improved = true } else { length /= 2 }
            }
            if !improved { break }
        }
        let result = gains(best), saturation = exp(best.z)
        guard result.x.isFinite, result.y.isFinite, result.z.isFinite, saturation.isFinite else { return (.one, 1) }
        return (result, saturation)
    }
    /// Water tone as the kernel applies it to a fully water-like pixel: chroma scaled around
    /// luminance (negative channels clip to zero), then the gains.
    static func toned(_ c: SIMD3<Float>, gains: SIMD3<Float>, saturation: Float) -> SIMD3<Float> {
        let y = (c * luma).sum()
        return pointwiseMax(SIMD3(repeating: y) + (c - SIMD3(repeating: y)) * saturation, .zero) * gains
    }

    /// The open-water colour after restoration. The water is far away, so it is estimated at the
    /// plan's mean depth, but when the veil model removed most of its light the estimate has no
    /// reliable hue, so the source water colour takes over.
    static func restoredWater(_ water: SIMD3<Float>, plan: RestorationPlan) -> SIMD3<Float> {
        let restored = restoredMean(water, plan: plan)
        let before = (water * luma).sum(), after = (restored * luma).sum()
        let kept = before > 1e-4 ? after / before : 1
        let trust = min(1, max(0, (kept - 0.2) / 0.3))
        let result = water + (restored - water) * trust
        return result.x.isFinite && result.y.isFinite && result.z.isFinite ? result : water
    }

    /// Luminance weights, the same ones analyze() and the kernels use.
    static let luma = SIMD3<Float>(0.2126, 0.7152, 0.0722)

    /// Scene mean colour after restoration, at the plan's mean depth (or at `depth`). It mirrors the
    /// restoration kernel on one colour and ignores highlight protection.
    static func restoredMean(_ mean: SIMD3<Float>, plan: RestorationPlan, depth: Float? = nil) -> SIMD3<Float> {
        let values = plan.depth.values
        let z = depth.map { min(1, max(0, $0.isFinite ? $0 : 0.5)) } ?? (values.isEmpty ? 0.5 : values.reduce(0, +) / Float(values.count))
        var restored = mean
        for channel in 0..<3 {
            let veil = max(0, plan.backscatterInfinity[channel]) * (1 - exp(-max(0, plan.betaBackscatter[channel]) * z))
            let transmission = max(max(0.01, plan.limits.transmissionFloor), exp(-max(0, plan.betaDirect[channel]) * z))
            let gain = min(1 / transmission, max(1, plan.limits.maximumGain[channel]))
            let recovery = min(1, max(0, plan.channelRecoverability[channel]))
            restored[channel] = mean[channel] + (max(0, mean[channel] - veil) * gain - mean[channel]) * recovery
        }
        restored = RestorationMath.keepHueWhereDark(source: mean, restored: restored)
        restored = RestorationMath.keepBlueFamily(source: mean, restored: restored)
        return restored.x.isFinite && restored.y.isFinite && restored.z.isFinite ? restored : mean
    }

    /// Lowest mid-tone lift. The curve stays monotonic down to -1; Brightness down reaches this.
    static let minimumMidLift: Float = -0.25

    /// Lift strength that moves linear luminance `from` to `to` with y = x + lift * x * (1 - x) in
    /// gamma space. Capped at 0.9 so the curve stays monotonic; zero when no lift is needed.
    static func midLift(from: Float, to: Float) -> Float {
        let x0 = pow(min(1, max(1e-4, from)), 1 / 2.2), x1 = pow(min(1, max(1e-4, to)), 1 / 2.2)
        guard x1 > x0, x0 < 0.999 else { return 0 }
        return min(0.9, (x1 - x0) / (x0 * (1 - x0)))
    }

    private func sanitized() -> Self {
        var v = self
        let fallback = Self.identity
        func fix(_ key: WritableKeyPath<Self, Float>) { if !v[keyPath: key].isFinite { v[keyPath: key] = fallback[keyPath: key] } }
        for key in [\Self.redRebuild, \.redGateLow, \.redGateHigh, \.subjectRed, \.waterRedness, \.waterSaturation, \.waterChroma, \.waterType, \.redCeiling, \.violetGuard, \.midLift, \.toneCurve, \.tonePivot,
                    \.brightness, \.contrast, \.saturation, \.shadowLift, \.highlightAmount, \.clarity, \.clarityRadius,
                    \.definition, \.definitionRadius, \.warmth, \.vibrance, \.physicalWeight] { fix(key) }
        if !(v.castGains.x.isFinite && v.castGains.y.isFinite && v.castGains.z.isFinite) { v.castGains = fallback.castGains }
        if !(v.waterTone.x.isFinite && v.waterTone.y.isFinite && v.waterTone.z.isFinite) { v.waterTone = fallback.waterTone }
        if !(v.waterLit.x.isFinite && v.waterLit.y.isFinite && v.waterLit.z.isFinite) { v.waterLit = fallback.waterLit }
        if !(v.neutralGains.x.isFinite && v.neutralGains.y.isFinite && v.neutralGains.z.isFinite) { v.neutralGains = fallback.neutralGains }
        v.midLift = min(0.9, max(Self.minimumMidLift, v.midLift))
        v.toneCurve = min(0.3, max(0, v.toneCurve))
        v.physicalWeight = min(1, max(0, v.physicalWeight))
        return v
    }

    #if DEBUG
    var logDescription: String {
        "gains=(\(castGains.x),\(castGains.y),\(castGains.z)) water=(\(waterTone.x),\(waterTone.y),\(waterTone.z))x\(waterSaturation)@\(waterRedness)/\(waterChroma) type=\(waterType) ceiling=\(redCeiling) guard=\(violetGuard) gate=\(redGateLow) redRebuild=\(redRebuild) subjectRed=\(subjectRed) midLift=\(midLift) curve=\(toneCurve)@\(tonePivot) brightness=\(brightness) contrast=\(contrast) saturation=\(saturation) shadows=\(shadowLift) clarity=\(clarity) definition=\(definition) warmth=\(warmth) vibrance=\(vibrance) physicalWeight=\(physicalWeight) neutral=(\(neutralGains.x),\(neutralGains.y),\(neutralGains.z))"
    }
    #endif
}

/// CPU mirror of the HydroToneFinishColor kernel. Unit tests use it; keep both equal.
enum FinishingMath {
    static func color(_ source: SIMD3<Float>, correction v: ColorCorrection) -> SIMD3<Float> {
        func smoothstep(_ low: Float, _ high: Float, _ x: Float) -> Float {
            let t = min(1, max(0, (x - low) / max(1e-5, high - low)))
            return t * t * (3 - 2 * t)
        }
        let input = SIMD3(source.x.isFinite ? max(0, source.x) : 0, source.y.isFinite ? max(0, source.y) : 0,
                          source.z.isFinite ? max(0, source.z) : 0)
        var c = input * SIMD3(max(0, v.castGains.x), max(0, v.castGains.y), max(0, v.castGains.z))
        let waterLike = waterLike(c, correction: v)
        // White reference: pixels that are not water-like, or clearly brighter than the water,
        // move with the scene's neutral surfaces.
        c *= SIMD3(repeating: 1) + (pointwiseMax(v.neutralGains, .zero) - 1) * neutralWeight(c, correction: v)
        c = ColorCorrection.violetGuard(c, input: input, waterLike: waterLike, strength: v.violetGuard)
        let lum = (c * ColorCorrection.luma).sum(), scale = 1 + (max(0, v.waterSaturation) - 1) * waterLike
        c = pointwiseMax(SIMD3(repeating: lum) + (c - SIMD3(repeating: lum)) * scale, .zero)
        c *= SIMD3(repeating: 1) + (SIMD3(max(0, v.waterTone.x), max(0, v.waterTone.y), max(0, v.waterTone.z)) - 1) * waterLike
        let greenBlue = c.y / max(c.z, 1e-4)
        let hue = smoothstep(v.redGateLow, v.redGateHigh, greenBlue) * (1 - smoothstep(1.35, 2.2, greenBlue))
        let subject = smoothstep(v.subjectRed, v.subjectRed + 0.3, c.x / max(c.y, 1e-4))
        let rebuilt = max(v.redRebuild, 0) * c.y * hue * (0.6 + 0.4 * subject)
        c.x += min(rebuilt, max(0, c.y * v.redCeiling - c.x))
        let l = (c * ColorCorrection.luma).sum()
        if l > 1e-5 && l < 1 {
            var x = pow(l, 1 / 2.2)
            x += max(ColorCorrection.minimumMidLift, v.midLift) * x * (1 - x)
            let y = min(1, max(0, x + 4 * v.toneCurve * (x - v.tonePivot) * x * (1 - x)))
            let peak = c.max()
            c *= min(pow(y, 2.2) / l, max(1, peak) / max(peak, 1e-5))
        }
        return c.x.isFinite && c.y.isFinite && c.z.isFinite ? c : input
    }
    /// Highlight shoulder, the last finishing step. The HydroToneHighlightShoulder kernel mirrors it.
    /// The largest channel is read as a BT.709 / sRGB display shows it (`display`), because the
    /// smallest output gamut clips first. The ceiling is white (1), or the reference pixel's own
    /// display peak when that is higher (an HDR highlight), so HDR headroom stays.
    /// - Below `ceiling - shoulderWidth` a pixel is unchanged.
    /// - Above it the whole pixel is scaled, so its largest channel rolls off smoothly toward the
    ///   ceiling and never reaches it. The hue stays.
    /// - A pixel that is bright in every channel (its smallest display channel `paleLow` to
    ///   `paleHigh` of the ceiling), or pushed far past the ceiling (`whiteLow` to `whiteHigh` times),
    ///   is a light source or a blown highlight. Its tint came from the gains, so it moves toward
    ///   white at the same peak. Without this the sun would show a pink ring.
    static func shoulder(_ c: SIMD3<Float>, reference: SIMD3<Float>) -> SIMD3<Float> {
        func smoothstep(_ low: Float, _ high: Float, _ x: Float) -> Float {
            let t = min(1, max(0, (x - low) / max(1e-5, high - low)))
            return t * t * (3 - 2 * t)
        }
        let shown = display(c), peak = shown.max(), ceiling = max(1, display(reference).max())
        let knee = ceiling - shoulderWidth
        guard peak.isFinite, peak > knee else { return c }
        let rolled = knee + shoulderWidth * (1 - exp(-(peak - knee) / shoulderWidth))
        let white = max(smoothstep(whiteLow, whiteHigh, peak / ceiling), smoothstep(paleLow, paleHigh, shown.min() / ceiling))
        let out = c * (rolled / peak) * (1 - white) + SIMD3(repeating: rolled) * white
        return out.x.isFinite && out.y.isFinite && out.z.isFinite ? out : c
    }
    static let shoulderWidth: Float = 0.15, whiteLow: Float = 1.3, whiteHigh: Float = 2
    static let paleLow: Float = 0.65, paleHigh: Float = 0.9
    /// Linear BT.2020 (the working space) to linear BT.709 / sRGB primaries. Standard colorimetry.
    static func display(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(1.660491 * c.x - 0.587641 * c.y - 0.072850 * c.z,
              -0.124550 * c.x + 1.132900 * c.y - 0.008349 * c.z,
              -0.018151 * c.x - 0.100579 * c.y + 1.118730 * c.z)
    }
    /// 0...1: how much the white reference acts on a colour (after the cast gains). Water-like
    /// pixels get none, unless they are 1.3 to 1.8 times brighter than the water and of another
    /// chromaticity (a pale belly). Brighter water of the water's own chromaticity gets none.
    /// The kernel mirrors it.
    static func neutralWeight(_ c: SIMD3<Float>, correction v: ColorCorrection) -> Float {
        func smoothstep(_ low: Float, _ high: Float, _ x: Float) -> Float {
            let t = min(1, max(0, (x - low) / max(1e-5, high - low)))
            return t * t * (3 - 2 * t)
        }
        let water = pointwiseMax(v.waterLit, .zero), lum = (c * ColorCorrection.luma).sum()
        let waterLum = (water * ColorCorrection.luma).sum()
        guard waterLum > 1e-4, c.sum() > 1e-5 else { return 1 - waterLike(c, correction: v) }
        // Chromaticity distance to the water: sum of |channel share - water channel share|.
        let apart = simd_reduce_add(abs(c / c.sum() - water / water.sum()))
        let bright = smoothstep(1.3, 1.8, lum / waterLum) * smoothstep(0.08, 0.2, apart)
        return 1 - waterLike(c, correction: v) * (1 - bright)
    }
    /// 0...1: how much a colour (after the cast gains) counts as open water.
    static func waterLike(_ c: SIMD3<Float>, correction v: ColorCorrection) -> Float {
        func smoothstep(_ low: Float, _ high: Float, _ x: Float) -> Float {
            let t = min(1, max(0, (x - low) / max(1e-5, high - low)))
            return t * t * (3 - 2 * t)
        }
        // Chroma separates silver subjects from strongly coloured water, but is unreliable
        // in murky water. Fading that test prevents small compression steps becoming grey patches.
        let redness = c.x / max(c.y + c.z, 1e-4)
        let top = c.max(), pixelChroma = top > 1e-4 ? (top - c.min()) / top : 0
        let chromaConfidence = smoothstep(0.55, 0.8, v.waterChroma)
        let chromaMatch = smoothstep(v.waterChroma * 0.5, v.waterChroma * 0.85, pixelChroma)
        return (1 - smoothstep(v.waterRedness, v.waterRedness + max(0.3, v.waterRedness * 0.6), redness))
            * (1 - (1 - chromaMatch) * chromaConfidence)
    }
}

final class FilterEngine: Sendable {
    // CIContext is thread safe. CIFilters are local to each invocation.
    let context: CIContext
    private let colorKernel: CIColorKernel?
    private let shoulderKernel: CIColorKernel?
    /// False when the finishing kernel failed to compile. Output then uses the weaker colour-matrix
    /// fallback, so owners with a DiagnosticRecorder report it.
    var finishingKernelAvailable: Bool { colorKernel != nil }
    static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    static let photoSpace = CGColorSpace(name: CGColorSpace.displayP3)!
    init() {
        let options: [CIContextOption: Any] = [.workingColorSpace: Self.workingSpace, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false]
        if let device = MTLCreateSystemDefaultDevice() { context = CIContext(mtlDevice: device, options: options) }
        else { context = CIContext(options: options) }
        let kernels = try? CIKernel.kernels(withMetalString: Self.colorSource)
        colorKernel = kernels?.first { $0.name == "HydroToneFinishColor" } as? CIColorKernel
        shoulderKernel = kernels?.first { $0.name == "HydroToneHighlightShoulder" } as? CIColorKernel
    }

    // Scene-level colour stage: cast gains, water tone, hue-gated red rebuild, mid-tone lift, luminance S-curve.
    // Every argument comes from one ColorCorrection, so video frames share one curve.
    // FinishingMath.color is the CPU mirror.
    private static let colorSource = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    [[stitchable]] float4 HydroToneFinishColor(coreimage::sample_t source, float4 gains, float4 water, float4 shape, float4 red, float4 tone, float4 neutral, float4 waterLit) {
        const float3 input = max(source.rgb, float3(0.0f));
        float3 c = input * max(gains.rgb, float3(0.0f));
        // Redder subjects stay protected, with a broad transition through similar water colours.
        // Only strongly coloured water (shape.y) reliably separates silver subjects by chroma.
        // In murky water, fading that test avoids amplifying compressed colour steps into patches.
        const float redness = c.r / max(c.g + c.b, 1e-4f);
        const float top = max(c.r, max(c.g, c.b));
        const float pixelChroma = top > 1e-4f ? (top - min(c.r, min(c.g, c.b))) / top : 0.0f;
        const float chromaConfidence = smoothstep(0.55f, 0.8f, shape.y);
        const float chromaMatch = smoothstep(shape.y * 0.5f, max(shape.y * 0.85f, shape.y * 0.5f + 1e-5f), pixelChroma);
        const float waterLike = (1.0f - smoothstep(water.w, water.w + max(0.3f, water.w * 0.6f), redness))
            * (1.0f - (1.0f - chromaMatch) * chromaConfidence);
        // White reference (neutral.rgb): pixels that are not water-like, or clearly brighter than
        // the water (waterLit.rgb) and of another chromaticity, move with the neutral surfaces.
        const float3 lw = max(waterLit.rgb, float3(0.0f));
        const float waterLum = dot(lw, float3(0.2126f, 0.7152f, 0.0722f));
        const float total = c.r + c.g + c.b;
        float bright = 0.0f;
        if (waterLum > 1e-4f && total > 1e-5f) {
            const float3 d = abs(c / total - lw / (lw.r + lw.g + lw.b));
            bright = smoothstep(1.3f, 1.8f, dot(c, float3(0.2126f, 0.7152f, 0.0722f)) / waterLum)
                * smoothstep(0.08f, 0.2f, d.r + d.g + d.b);
        }
        c *= mix(float3(1.0f), max(neutral.rgb, float3(0.0f)), 1.0f - waterLike * (1.0f - bright));
        // In a blue pixel, red above green reads violet: gains may not lift red past green or the
        // pixel's own red. In water-like pixels (weighted by shape.w) red stops at green.
        const float blue = smoothstep(1.3f, 2.0f, c.b / max(max(c.r, c.g), 1e-4f));
        const float limit = mix(max(input.r, c.g), c.g, clamp(waterLike * shape.w, 0.0f, 1.0f));
        c.r = mix(c.r, min(c.r, limit), blue);
        // Water chroma scale (shape.x) around luminance calms neon water; then the water gains.
        const float y0 = dot(c, float3(0.2126f, 0.7152f, 0.0722f));
        c = max(float3(y0) + (c - float3(y0)) * mix(1.0f, max(shape.x, 0.0f), waterLike), float3(0.0f));
        c *= mix(float3(1.0f), max(water.rgb, float3(0.0f)), waterLike);
        // Rebuild red from green only where green is near blue. Blue water gets almost none,
        // so it cannot drift to violet. Strongly green pixels also get little, so green
        // water and weed do not turn yellow. Pixels redder than the water get a little more.
        const float greenBlue = c.g / max(c.b, 1e-4f);
        const float hue = smoothstep(red.y, red.z, greenBlue) * (1.0f - smoothstep(1.35f, 2.2f, greenBlue));
        const float subject = smoothstep(red.w, red.w + 0.3f, c.r / max(c.g, 1e-4f));
        // Rebuilt red stops at shape.z times green, so grey subjects stay grey.
        c.r += min(max(red.x, 0.0f) * c.g * hue * (0.6f + 0.4f * subject), max(0.0f, c.g * shape.z - c.r));
        // Mid-tone lift, then an S-curve around the scene median, both on gamma luminance.
        // Zero and one stay fixed.
        const float l = dot(c, float3(0.2126f, 0.7152f, 0.0722f));
        if (l > 1e-5f && l < 1.0f) {
            float x = pow(l, 1.0f / 2.2f);
            // A negative lift (Brightness down) darkens; -0.25 is ColorCorrection.minimumMidLift.
            x += max(tone.z, -0.25f) * x * (1.0f - x);
            const float y = clamp(x + 4.0f * tone.x * (x - tone.y) * x * (1.0f - x), 0.0f, 1.0f);
            const float peak = max(c.r, max(c.g, c.b));
            // Cap the gain so no channel crosses one, and HDR peaks above one never grow.
            c *= min(pow(y, 2.2f) / l, max(1.0f, peak) / max(peak, 1e-5f));
        }
        if (!all(isfinite(c))) { c = input; }
        return float4(c, source.a);
    }

    // Highlight shoulder, the last finishing step. FinishingMath.shoulder is the CPU mirror.
    // The peak is read in BT.709 primaries; the ceiling is white or the reference's own (HDR) peak.
    // shape: x = shoulder width, y and z = the overshoot range, w = the start of the pale range.
    // pale.x = the end of the pale range. Both ranges move a pixel toward white.
    [[stitchable]] float4 HydroToneHighlightShoulder(coreimage::sample_t source, coreimage::sample_t reference, float4 shape, float4 pale) {
        const float3x3 display = float3x3(float3(1.660491f, -0.124550f, -0.018151f),
                                          float3(-0.587641f, 1.132900f, -0.100579f),
                                          float3(-0.072850f, -0.008349f, 1.118730f));
        const float3 c = source.rgb;
        const float3 d = display * c, r = display * reference.rgb;
        const float peak = max(d.r, max(d.g, d.b));
        const float ceiling = max(1.0f, max(r.r, max(r.g, r.b)));
        const float width = max(shape.x, 1e-4f), knee = ceiling - width;
        if (!(peak > knee) || !isfinite(peak)) { return source; }
        const float rolled = knee + width * (1.0f - exp(-(peak - knee) / width));
        const float white = max(smoothstep(shape.y, shape.z, peak / ceiling),
                                smoothstep(shape.w, pale.x, min(d.r, min(d.g, d.b)) / ceiling));
        const float3 out = mix(c * (rolled / peak), float3(rolled), white);
        return all(isfinite(out)) ? float4(out, source.a) : source;
    }
    """

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
        controls.contrast = v.contrast
        controls.saturation = v.saturation
        controls.brightness = v.brightness
        corrected = controls.outputImage ?? corrected

        let shadows = CIFilter.highlightShadowAdjust()
        shadows.inputImage = corrected
        shadows.shadowAmount = v.shadowLift
        shadows.highlightAmount = v.highlightAmount
        corrected = shadows.outputImage ?? corrected

        let side = Float(min(image.extent.width, image.extent.height))
        let short = side.isFinite && side > 0 ? side : 480
        for (amount, radius) in [(v.clarity, v.clarityRadius), (v.definition, v.definitionRadius)] where amount > 0 {
            let mask = CIFilter.unsharpMask()
            mask.inputImage = corrected
            mask.radius = max(1, radius * short)
            mask.intensity = amount
            corrected = mask.outputImage ?? corrected
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
        return colorKernel.apply(extent: image.extent, arguments: [
            image, CIVector(x: CGFloat(v.castGains.x), y: CGFloat(v.castGains.y), z: CGFloat(v.castGains.z), w: 0),
            CIVector(x: CGFloat(v.waterTone.x), y: CGFloat(v.waterTone.y), z: CGFloat(v.waterTone.z), w: CGFloat(v.waterRedness)),
            CIVector(x: CGFloat(v.waterSaturation), y: CGFloat(v.waterChroma), z: CGFloat(v.redCeiling), w: CGFloat(v.violetGuard)),
            CIVector(x: CGFloat(v.redRebuild), y: CGFloat(v.redGateLow), z: CGFloat(v.redGateHigh), w: CGFloat(v.subjectRed)),
            CIVector(x: CGFloat(v.toneCurve), y: CGFloat(v.tonePivot), z: CGFloat(v.midLift), w: 0),
            CIVector(x: CGFloat(v.neutralGains.x), y: CGFloat(v.neutralGains.y), z: CGFloat(v.neutralGains.z), w: 0),
            CIVector(x: CGFloat(v.waterLit.x), y: CGFloat(v.waterLit.y), z: CGFloat(v.waterLit.z), w: 0)
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
        var lit: Float = 0, high: Float = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = pixels[i], g = pixels[i+1], b = pixels[i+2]
            let l = r * 0.2126 + g * 0.7152 + b * 0.0722
            // Bright share counts clipped pixels too: a blown white belly is a bright area.
            if l.isFinite, l > 0.015 { lit += 1; if l >= 0.35 { high += 1 } }
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
            highShare: lit > 0 ? high / lit : 0)
    }
}
