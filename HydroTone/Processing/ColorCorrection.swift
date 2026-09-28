import Foundation
import simd

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
    /// Light removal on subjects: gains (red 1, green and blue at or below the water's own share) for
    /// pixels that are not water-like, applied at the pixel's own luminance. One means no removal.
    var subjectTone = SIMD3<Float>(repeating: 1)
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
                                 ceiling: ceiling, murkyFloor: 0.22 / later)
        // More chroma than the water has is only for murky water; elsewhere it would push
        // water-coloured subjects (silver fish, blue reef) away from grey and take their red.
        let tone = waterCorrection(from: seen, to: target, maximumSaturation: target.y > seenLCh.y + 0.005 ? 1.6 : 1)
        // A colourful reef can make the scene mean look neutral while the open water is clearly
        // blue, so the water's own chroma also counts. A grey scene has grey "water" and gets none.
        let cast = max(analysis.castStrength, min(1, max(0, (oklch(water).y - 0.03) / 0.05)))
        v.waterTone = SIMD3(pow(tone.gains.x, cast), pow(tone.gains.y, cast), pow(tone.gains.z, cast))
        v.waterSaturation = pow(tone.saturation, cast)
        // Subjects are lit through the same water, so they carry its colour: blue, or green in green
        // water. The red boost alone then leaves a reef violet and a white belly mint. So pixels that
        // are not water-like lose part of the water's colour: green and blue against red, by
        // subjectLightRemoval of the water's own ratios, at the pixel's own luminance. Green never
        // rises: water with less green than red left no green to give back, and extra green turns a
        // fish lime. The white reference below reads the result, so a neutral surface needs less
        // from it. Grey water gets none.
        let light = pointwiseMax(lit, SIMD3(repeating: 1e-3))
        let removal = subjectLightRemoval * cast
        v.subjectTone = SIMD3(1, min(1, max(0.6, pow(light.x / light.y, removal))),
                              min(1, max(0.35, pow(light.x / light.z, removal))))
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
        // Global contrast alone can bury a dark diver or reef, so lift the lower tones. The lift
        // reaches the mid-tones too, so it stays moderate: the market look sits 3 to 6 L* below the
        // earlier values in the mid-tones, with the same shadows.
        v.shadowLift = 0.2 + haze * 0.15 * (1 - 0.6 * highlight) + bright * 0.1
        v.shadowLift += max(0, user.brightness) * Caps.brightnessUp
        // Hazy scenes get their highlights compressed: every lift above pushes them up, and the
        // market look keeps the highlights 5 to 10 L* lower than the earlier values did.
        v.highlightAmount = 0.92 - 0.2 * haze
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
        // A scene lit by a large bright subject is exposed for that subject, so its mid-tones may go a
        // little darker (the highlight rule, both paths). Brightness down lowers the mid-tones on both
        // paths. The white reference below sees the result.
        v.midLift = min(0.9, max(minimumMidLift, v.midLift - 0.12 * highlight + min(0, user.brightness) * Caps.brightnessDown))
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
        // Only a pale remainder counts (OKLab chroma below 0.10, none from 0.18): the candidates are
        // the bright, low-chroma surfaces, so a pale remainder of any hue is a cast. A colourful
        // remainder is a real colour, such as a yellow fish, and is kept.
        let pale = 1 - smoothstep(0.10, 0.18, lch.y)
        // A strongly blue reference is trusted too: a white belly, a grey fish or sand lit by blue
        // water is as blue as pale water near the surface, and no colour test tells them apart. The
        // open water is safe either way, because the kernel applies the gains by neutralWeight, which
        // leaves water-like pixels alone unless they are clearly brighter than the water and of
        // another chromaticity.
        let strength = evidence * pale * FinishingMath.neutralWeight(seen * v.castGains, correction: v)
        guard strength > 0.001 else { return .one }
        // The reference removes a water cast, which is cool: red may rise up to 3 times, green and
        // blue may fall to half, and none moves the other way. A warm remainder is a real colour, or
        // the restoration's own red, and gets gains of one. (Extra green also turns fish lime.)
        let low = SIMD3<Float>(1, 0.5, 0.5), high = SIMD3<Float>(3, 1, 1)
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
        if !(v.subjectTone.x.isFinite && v.subjectTone.y.isFinite && v.subjectTone.z.isFinite) { v.subjectTone = fallback.subjectTone }
        v.midLift = min(0.9, max(Self.minimumMidLift, v.midLift))
        v.toneCurve = min(0.3, max(0, v.toneCurve))
        v.physicalWeight = min(1, max(0, v.physicalWeight))
        return v
    }

    #if DEBUG
    var logDescription: String {
        "gains=(\(castGains.x),\(castGains.y),\(castGains.z)) water=(\(waterTone.x),\(waterTone.y),\(waterTone.z))x\(waterSaturation)@\(waterRedness)/\(waterChroma) type=\(waterType) ceiling=\(redCeiling) guard=\(violetGuard) gate=\(redGateLow) redRebuild=\(redRebuild) subjectRed=\(subjectRed) midLift=\(midLift) curve=\(toneCurve)@\(tonePivot) brightness=\(brightness) contrast=\(contrast) saturation=\(saturation) shadows=\(shadowLift) clarity=\(clarity) definition=\(definition) warmth=\(warmth) vibrance=\(vibrance) physicalWeight=\(physicalWeight) neutral=(\(neutralGains.x),\(neutralGains.y),\(neutralGains.z)) subject=(\(subjectTone.x),\(subjectTone.y),\(subjectTone.z))"
    }
    #endif
}
