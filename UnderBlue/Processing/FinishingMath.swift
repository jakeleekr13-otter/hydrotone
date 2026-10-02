import Foundation
import simd

/// CPU mirror of the UnderBlueFinishColor kernel. Unit tests use it; keep both equal.
enum FinishingMath {
    static func color(_ source: SIMD3<Float>, correction v: ColorCorrection,
                      referenceInput: SIMD3<Float>? = nil) -> SIMD3<Float> {
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
        let neutral = neutralWeight(c, correction: v)
        var adaptation = neutral * smoothstep(0.04, 0.16, (input * ColorCorrection.luma).sum())
        // Green anchors the exposure estimate. Once it clips, channel ratios no longer
        // describe the surface; keep the established highlight correction there.
        adaptation *= 1 - smoothstep(0.8, 0.9, display(input).y)
        c *= SIMD3(repeating: 1) + (pointwiseMax(v.neutralGains, .zero) - 1) * neutral
        // A bright pixel that the white reference made nearly grey is a pale surface, not water.
        // The water saturation and the water tone skip it; as a cast on grey they read violet or green.
        // Bright water that is still coloured keeps them. `neutral - (1 - waterLike)` is the bright share.
        let top = c.max(), paleChroma = top > 1e-4 ? (top - c.min()) / top : 0
        let pale = 1 - smoothstep(0.15, 0.35, paleChroma)
        let water = waterLike - max(0, neutral - (1 - waterLike)) * pale
        // Light removal on subjects: pixels that are not water-like lose part of the water's colour,
        // at their own luminance. Green and blue never fall below the pixel's red: a grey subject
        // carries no cast to remove, so it is not made warm.
        var removed = c * (SIMD3(repeating: 1) + (pointwiseMax(v.subjectTone, .zero) - 1) * (1 - waterLike))
        removed.y = max(removed.y, min(c.y, c.x)); removed.z = max(removed.z, min(c.z, c.x))
        // The removal never makes a pixel greener: blue keeps at least its share of green. It takes
        // more blue than green, so a cyan-lit pale surface would otherwise end green.
        removed.z = max(removed.z, removed.y * min(1, c.z / max(c.y, 1e-4)))
        let kept = (c * ColorCorrection.luma).sum(), left = (removed * ColorCorrection.luma).sum()
        if left > 1e-6 { c = removed * (kept / left) }
        c = ColorCorrection.violetGuard(c, input: input, waterLike: waterLike, strength: v.violetGuard)
        let lum = (c * ColorCorrection.luma).sum(), scale = 1 + (max(0, v.waterSaturation) - 1) * water
        c = pointwiseMax(SIMD3(repeating: lum) + (c - SIMD3(repeating: lum)) * scale, .zero)
        c *= SIMD3(repeating: 1) + (SIMD3(max(0, v.waterTone.x), max(0, v.waterTone.y), max(0, v.waterTone.z)) - 1) * water
        let greenBlue = c.y / max(c.z, 1e-4)
        let hue = smoothstep(v.redGateLow, v.redGateHigh, greenBlue) * (1 - smoothstep(1.35, 2.2, greenBlue))
        let subject = smoothstep(v.subjectRed, v.subjectRed + 0.3, c.x / max(c.y, 1e-4))
        let rebuilt = max(v.redRebuild, 0) * c.y * hue * (0.6 + 0.4 * subject)
        c.x += min(rebuilt, max(0, c.y * v.redCeiling - c.x))
        if v.referenceStrength > 0 {
            let shown = pointwiseMax(display(referenceInput ?? input), .zero) * v.referenceGains
            let chroma = shown.max() > 1e-4 ? (shown.max() - shown.min()) / shown.max() : 0
            // The geometric exposure must not dim an already bright, nearly neutral surface.
            adaptation *= 1 - smoothstep(0.5, 0.8, (input * ColorCorrection.luma).sum()) * (1 - smoothstep(0.15, 0.45, chroma))
            let adapted = working(shown)
            c += (adapted - c) * (v.referenceStrength * adaptation)
        }
        let l = (c * ColorCorrection.luma).sum()
        if l > 1e-5 && l < 1 {
            var x = pow(l, 1 / 2.2)
            x += max(ColorCorrection.minimumMidLift, v.midLift) * x * (1 - x)
            let y = min(1, max(0, x + 4 * v.toneCurve * (x - v.tonePivot) * x * (1 - x)))
            let peak = c.max()
            c *= min(pow(y, 2.2) / l, max(1, peak) / max(peak, 1e-5))
        }
        // Smooth the RGB black offset on adapted subjects. Unlike a hard subtraction/clamp,
        // the toe keeps small channel differences and maps a true zero to zero.
        if v.referenceStrength > 0 {
            let offset = v.brightness + (1 - v.contrast) * 0.5
            let linear = c * max(0, v.contrast) + SIMD3(repeating: offset)
            var soft = linear
            if offset < 0 {
                let floor = 0.5 * (offset + sqrt(offset * offset + 0.0004))
                for channel in 0..<3 {
                    let x = linear[channel]
                    soft[channel] = max(0, 0.5 * (x + sqrt(x * x + 0.0004)) - floor)
                }
            }
            c += (linear + (soft - linear) * adaptation - c) * v.referenceStrength
        }
        return c.x.isFinite && c.y.isFinite && c.z.isFinite ? c : input
    }
    /// Fine detail layer, applied after the unsharp masks. The UnderBlueDetail kernel mirrors it.
    /// `c` is the pixel after the unsharp masks, `blurred` the same pixel blurred by detailRadius, and
    /// `reference` the finishing input (the source, or the restored image), which the water-like test reads.
    /// - The layer is the gamma-luminance difference between the pixel and its blur.
    /// - Differences below detailFloor are noise and get nothing; the strength is full from three times
    ///   the floor. Differences above detailEdgeLow fade out by detailEdgeHigh: a strong edge gets
    ///   nothing, so no halo is added.
    /// - The layer lands where the white reference lands (neutralWeight): subjects, and pale surfaces
    ///   clearly brighter than the water. Open water gets nothing. Dark pixels (linear luminance
    ///   detailShadowLow to detailShadowHigh) fade in: they carry the most noise and show the least detail.
    /// - The pixel is scaled by one factor, so its hue and chroma stay. No channel crosses one, and a
    ///   pixel at or above luminance one (an HDR peak) is unchanged.
    static func detail(_ c: SIMD3<Float>, blurred: SIMD3<Float>, reference: SIMD3<Float>, correction v: ColorCorrection) -> SIMD3<Float> {
        func smoothstep(_ low: Float, _ high: Float, _ x: Float) -> Float {
            let t = min(1, max(0, (x - low) / max(1e-5, high - low)))
            return t * t * (3 - 2 * t)
        }
        let l = (pointwiseMax(c, .zero) * ColorCorrection.luma).sum(), lb = (pointwiseMax(blurred, .zero) * ColorCorrection.luma).sum()
        guard l.isFinite, lb.isFinite, l > 1e-5, l < 1, v.detail > 0 else { return c }
        let x = pow(l, 1 / 2.2), d = x - pow(lb, 1 / 2.2), a = abs(d)
        let band = smoothstep(v.detailFloor, max(3 * v.detailFloor, v.detailFloor + 1e-5), a) * (1 - smoothstep(detailEdgeLow, detailEdgeHigh, a))
        let lit = smoothstep(detailShadowLow, detailShadowHigh, l)
        let subject = neutralWeight(pointwiseMax(reference, .zero) * pointwiseMax(v.castGains, .zero), correction: v)
        let weight = max(0, v.detail) * band * subject * lit
        let y = max(0, x + weight * d)
        let peak = c.max()
        let out = c * min(pow(y, 2.2) / l, max(1, peak) / max(peak, 1e-5))
        return out.x.isFinite && out.y.isFinite && out.z.isFinite ? out : c
    }
    /// The detail band's upper edge (gamma luminance): from detailEdgeLow the layer fades, at
    /// detailEdgeHigh it is off. Fine texture sits below 0.15 (the mola's 90th percentile is 0.03 to
    /// 0.08); an outline is above 0.3. The shadow fade is in linear luminance.
    static let detailEdgeLow: Float = 0.15, detailEdgeHigh: Float = 0.30
    static let detailShadowLow: Float = 0.02, detailShadowHigh: Float = 0.06

    /// Contrast gain and black offset, as CIColorControls computes them: c * gain + offset. Measured
    /// on the Mac, CIColorControls is exactly c * contrast + brightness + (1 - contrast) / 2 per channel,
    /// with no clip, and its saturation commutes with it. The UnderBlueBlackOffset kernel mirrors this.
    /// A negative offset clipped every channel darker than it to black at output. A dark manta in a
    /// bright scene (video2 at 5 s, 30 Sep 2026) lost its whole body: 41% of that region near black, source 11%.
    /// So below twice the offset a quadratic toe takes over. Zero stays zero, and the toe meets the
    /// straight line with the same slope, so every channel from twice the offset up is as before.
    static func blackOffset(_ c: SIMD3<Float>, gain: Float, offset: Float) -> SIMD3<Float> {
        var out = c * gain + offset
        guard offset < 0 else { return out }
        let knee = -2 * offset
        for channel in 0..<3 {
            let x = c[channel] * gain
            if x < knee { out[channel] = max(0, x) * max(0, x) / (2 * knee) }
        }
        return out
    }

    /// Highlight shoulder, the last finishing step. The UnderBlueHighlightShoulder kernel mirrors it.
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

    /// Light detail. Inside bright light (light rays below the surface) the tone curve compresses the
    /// top of the range, so the rays merged into one flat patch. In IMG_7400 (2 Oct 2026) the output
    /// rose 0.89 per unit of source lightness there; AquaColorFix rose 1.34.
    /// So where the broad light (`base`, a blur of lightDetailRadius of the short side) is bright,
    /// the pixel's difference from it grows by lightDetailAmount, on gamma luminance. A large
    /// difference is an edge (a dark wing against the light). It gets none, so no rim appears.
    /// The kernel mirrors it.
    static func lightDetail(_ c: SIMD3<Float>, base: SIMD3<Float>) -> SIMD3<Float> {
        func smoothstep(_ low: Float, _ high: Float, _ x: Float) -> Float {
            let t = min(1, max(0, (x - low) / max(1e-5, high - low)))
            return t * t * (3 - 2 * t)
        }
        let l = (c * ColorCorrection.luma).sum(), lb = (base * ColorCorrection.luma).sum()
        guard l > 1e-5, lb > 0, l.isFinite, lb.isFinite else { return c }
        let y = pow(l, 1 / 2.2), b = pow(lb, 1 / 2.2), d = y - b
        let w = smoothstep(lightDetailLow, lightDetailHigh, b) * (1 - smoothstep(lightDetailEdgeLow, lightDetailEdgeHigh, abs(d)))
        let shaped = min(max(y + d * lightDetailAmount * w, 0), max(1, y))
        let out = c * (pow(shaped, 2.2) / l)
        return out.x.isFinite && out.y.isFinite && out.z.isFinite ? out : c
    }
    static let lightDetailAmount: Float = 1.3, lightDetailRadius: Float = 0.018
    static let lightDetailLow: Float = 0.5, lightDetailHigh: Float = 0.7
    static let lightDetailEdgeLow: Float = 0.06, lightDetailEdgeHigh: Float = 0.15
    static let paleLow: Float = 0.65, paleHigh: Float = 0.9
    /// Linear BT.2020 (the working space) to linear BT.709 / sRGB primaries. Standard colorimetry.
    static func display(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(1.660491 * c.x - 0.587641 * c.y - 0.072850 * c.z,
              -0.124550 * c.x + 1.132900 * c.y - 0.008349 * c.z,
              -0.018151 * c.x - 0.100579 * c.y + 1.118730 * c.z)
    }
    /// Linear sRGB to the linear Rec. 2020 working primaries.
    static func working(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(0.627404 * c.x + 0.329283 * c.y + 0.043313 * c.z,
              0.069097 * c.x + 0.919540 * c.y + 0.011362 * c.z,
              0.016391 * c.x + 0.088013 * c.y + 0.895595 * c.z)
    }
    /// 0...1: how much the white reference acts on a colour (after the cast gains). Water-like
    /// pixels get none, unless they are 2.2 to 3.2 times brighter than the water and of another
    /// chromaticity (a pale belly). Brighter water of the water's own chromaticity gets none.
    /// In a scene with a strong light source the range is 2.5 to 8 times (lightBrightLow/High).
    /// The kernel mirrors it. At 1.3 to 1.8 times, sunlit water (IMG_7400 light rays) turned grey
    /// with a lavender edge; with no exception, a pale manta kept a teal tint (1 Oct 2026).
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
        let g = min(1, max(0, v.lightGradient))
        let low = brightLow + (lightBrightLow - brightLow) * g, high = brightHigh + (lightBrightHigh - brightHigh) * g
        let bright = smoothstep(low, high, lum / waterLum) * smoothstep(0.08, 0.2, apart)
        return 1 - waterLike(c, correction: v) * (1 - bright)
    }
    /// "Clearly brighter" for neutralWeight: 2.2 to 3.2 times the water's luma; with a strong light
    /// source (ColorCorrection.lightGradient 1) 2.5 to 8 times. The colour kernel mirrors both.
    static let brightLow: Float = 2.2, brightHigh: Float = 3.2
    static let lightBrightLow: Float = 2.5, lightBrightHigh: Float = 8
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
