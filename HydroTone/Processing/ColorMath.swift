import Foundation
import simd

/// Colour-space conversions, the water target and its solver, the restoration mirror and the lift curve.
/// Pure functions of ColorCorrection; make() and FinishingMath call them.
extension ColorCorrection {
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

    /// Clear-water target in OKLab (L, C, hue): same lightness, hue moved to azure (waterHueGoal),
    /// chroma kept natural. The move is in full: the market look puts every clear-water scene near
    /// one azure, whatever the source hue. Near-grey water keeps its hue. Colours no open water
    /// has (red to yellow, and violet or magenta such as a large anemone) are not water, so they
    /// keep hue and chroma.
    /// `source` is the OKLCh of the untouched water colour; plausibility is judged on it, because
    /// the red boost can move restored water toward violet.
    static func waterTarget(_ water: SIMD3<Float>, waterType: Float, murky: Float, keep: Float = 0,
                            source: SIMD3<Float>? = nil, ceiling: Float = 0.07, murkyFloor: Float = 0.085) -> SIMD3<Float> {
        let goal = waterHueGoal
        let plausible = waterPlausibility(source ?? water)
        let hueWeight = min(1, max(0, (water.y - 0.015) / 0.025)) * plausible
        let hue = water.z + (goal - water.z) * hueWeight
        // Neon water is calmed; murky, deep water gets back some colour. The restored path keeps
        // part of the source chroma (`keep`), but never above the ceiling.
        let floor = max(murkyFloor * murky, min(keep, ceiling))
        let chroma = water.y + (max(floor, min(ceiling, water.y)) - water.y) * plausible
        return SIMD3(water.x, chroma, hue)
    }

    /// The OKLab hue every clear-water scene is moved to: azure. Cyan is about 200, pure blue 264.
    static let waterHueGoal: Float = 240
    /// Share of the water's colour taken from subjects (see subjectTone), as an exponent on the
    /// water's green/red and blue/red ratios.
    static let subjectLightRemoval: Float = 0.4

    /// Per-channel gains plus a chroma scale (around luminance) that move `from` to the OKLab
    /// target at the same luminance. Gains stay inside 0.35...2.2 and the chroma scale inside
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
            return SIMD3(min(2.2, max(0.35, g.x)), min(2.2, max(0.35, g.y)), min(2.2, max(0.35, g.z)))
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
            SIMD3(min(0.4, max(-0.5, p.x)), min(0.85, max(-0.85, p.y)), min(topScale, max(log(0.25), p.z)))
        }
        // A coarse grid first: nearly single-channel water (green almost zero) has flat
        // directions where a local solve stalls. Then a few damped Gauss-Newton steps.
        var best = SIMD3<Float>(0, 0, 0), bestCost = cost(best)
        for x in stride(from: Float(-0.5), through: 0.4, by: 0.1) {
            for y in stride(from: Float(-0.85), through: 0.85, by: 0.17) {
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
        // Polish with a short pattern search: a damped step can stop a degree or two short of the goal.
        var delta: Float = 0.02
        for _ in 0..<40 {
            var moved = false
            for axis in 0..<3 {
                for sign: Float in [1, -1] {
                    var p = best; p[axis] += sign * delta; p = bounded(p)
                    let c = cost(p)
                    if c.isFinite, c < bestCost { best = p; bestCost = c; moved = true }
                }
            }
            if !moved { delta /= 2; if delta < 1e-4 { break } }
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

}
