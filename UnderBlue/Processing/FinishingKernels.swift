import Foundation

/// The Metal sources of the finishing kernels. FilterEngine compiles them at init; FinishingMath mirrors them.
extension FilterEngine {

    // Scene-level colour stage: cast gains, water tone, hue-gated red rebuild, mid-tone lift, luminance S-curve.
    // Every argument comes from one ColorCorrection, so video frames share one curve.
    // FinishingMath.color is the CPU mirror.
    static let colorSource = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    [[stitchable]] float4 UnderBlueFinishColor(coreimage::sample_t source, coreimage::sample_t referenceInput, float4 gains, float4 water, float4 shape, float4 red, float4 tone, float4 neutral, float4 waterLit, float4 subjectTone, float4 reference) {
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
        // A bright pixel that the white reference made nearly grey is a pale surface, not water:
        // the water saturation and the water tone below skip it. FinishingMath.color mirrors it.
        const float paleTop = max(c.r, max(c.g, c.b));
        const float paleChroma = paleTop > 1e-4f ? (paleTop - min(c.r, min(c.g, c.b))) / paleTop : 0.0f;
        const float waterShare = waterLike * (1.0f - bright * (1.0f - smoothstep(0.15f, 0.35f, paleChroma)));
        // Light removal on subjects (subjectTone.rgb): pixels that are not water-like lose part of the
        // water's colour, at their own luminance. Green and blue never fall below the pixel's red, so
        // a grey subject is not made warm. FinishingMath.color mirrors it.
        {
            float3 removed = c * mix(float3(1.0f), max(subjectTone.rgb, float3(0.0f)), 1.0f - waterLike);
            removed.gb = max(removed.gb, min(c.gb, float2(c.r)));
            // The removal never makes a pixel greener: blue keeps at least its share of green.
            removed.b = max(removed.b, removed.g * min(1.0f, c.b / max(c.g, 1e-4f)));
            const float kept = dot(c, float3(0.2126f, 0.7152f, 0.0722f));
            const float left = dot(removed, float3(0.2126f, 0.7152f, 0.0722f));
            if (left > 1e-6f) { c = removed * (kept / left); }
        }
        // In a blue pixel, red above green reads violet: gains may not lift red past green or the
        // pixel's own red. In water-like pixels (weighted by shape.w) red stops at green.
        const float blue = smoothstep(1.3f, 2.0f, c.b / max(max(c.r, c.g), 1e-4f));
        const float limit = mix(max(input.r, c.g), c.g, clamp(waterLike * shape.w, 0.0f, 1.0f));
        c.r = mix(c.r, min(c.r, limit), blue);
        // Water chroma scale (shape.x) around luminance calms neon water; then the water gains.
        const float y0 = dot(c, float3(0.2126f, 0.7152f, 0.0722f));
        c = max(float3(y0) + (c - float3(y0)) * mix(1.0f, max(shape.x, 0.0f), waterShare), float3(0.0f));
        c *= mix(float3(1.0f), max(water.rgb, float3(0.0f)), waterShare);
        // Rebuild red from green only where green is near blue. Blue water gets almost none,
        // so it cannot drift to violet. Strongly green pixels also get little, so green
        // water and weed do not turn yellow. Pixels redder than the water get a little more.
        const float greenBlue = c.g / max(c.b, 1e-4f);
        const float hue = smoothstep(red.y, red.z, greenBlue) * (1.0f - smoothstep(1.35f, 2.2f, greenBlue));
        const float subject = smoothstep(red.w, red.w + 0.3f, c.r / max(c.g, 1e-4f));
        // Rebuilt red stops at shape.z times green, so grey subjects stay grey.
        c.r += min(max(red.x, 0.0f) * c.g * hue * (0.6f + 0.4f * subject), max(0.0f, c.g * shape.z - c.r));
        float surface = (1.0f - waterLike * (1.0f - bright))
            * smoothstep(0.04f, 0.16f, dot(input, float3(0.2126f, 0.7152f, 0.0722f)));
        surface *= 1.0f - smoothstep(0.8f, 0.9f, dot(input, float3(-0.124550f, 1.132900f, -0.008349f)));
        if (reference.w > 0.0f) {
            float3 shown = float3(dot(referenceInput.rgb, float3(1.660491f, -0.587641f, -0.072850f)),
                                  dot(referenceInput.rgb, float3(-0.124550f, 1.132900f, -0.008349f)),
                                  dot(referenceInput.rgb, float3(-0.018151f, -0.100579f, 1.118730f)));
            shown = max(shown, float3(0.0f)) * reference.rgb;
            const float shownTop = max(shown.r, max(shown.g, shown.b));
            const float shownChroma = shownTop > 1e-4f ? (shownTop - min(shown.r, min(shown.g, shown.b))) / shownTop : 0.0f;
            surface *= 1.0f - smoothstep(0.5f, 0.8f, dot(input, float3(0.2126f, 0.7152f, 0.0722f)))
                * (1.0f - smoothstep(0.15f, 0.45f, shownChroma));
            const float3 adapted = float3(dot(shown, float3(0.627404f, 0.329283f, 0.043313f)),
                                          dot(shown, float3(0.069097f, 0.919540f, 0.011362f)),
                                          dot(shown, float3(0.016391f, 0.088013f, 0.895595f)));
            c = mix(c, adapted, reference.w * surface);
        }
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
        if (reference.w > 0.0f) {
            const float3 linear = c * max(0.0f, neutral.w) + tone.w;
            float3 soft = linear;
            if (tone.w < 0.0f) {
                const float floor = 0.5f * (tone.w + sqrt(tone.w * tone.w + 0.0004f));
                soft = max(float3(0.0f), 0.5f * (linear + sqrt(linear * linear + 0.0004f)) - floor);
            }
            c = mix(c, mix(linear, soft, surface), reference.w);
        }
        if (!all(isfinite(c))) { c = input; }
        return float4(c, source.a);
    }

    // Fine detail layer, after the unsharp masks. FinishingMath.detail is the CPU mirror.
    // source = the pixel after the unsharp masks, blurred = its blur at detailRadius, reference = the
    // finishing input (what the colour kernel judged as water). gains = castGains,
    // water = (waterRedness, waterChroma), waterLit = the water after the gains, detail = (strength,
    // floor, edgeLow, edgeHigh), shadow = (shadowLow, shadowHigh). Luminance only, in a band, where the
    // white reference lands (the colour kernel's neutral weight): subjects and pale surfaces brighter
    // than the water. Open water gets nothing.
    [[stitchable]] float4 UnderBlueDetail(coreimage::sample_t source, coreimage::sample_t blurred, coreimage::sample_t reference, float4 gains, float4 water, float4 waterLit, float4 detail, float4 shadow) {
        const float3 c = source.rgb;
        const float3 luma = float3(0.2126f, 0.7152f, 0.0722f);
        const float l = dot(max(c, float3(0.0f)), luma), lb = dot(max(blurred.rgb, float3(0.0f)), luma);
        if (!isfinite(l) || !isfinite(lb) || !(l > 1e-5f) || !(l < 1.0f) || !(detail.x > 0.0f)) { return source; }
        const float x = pow(l, 1.0f / 2.2f), d = x - pow(lb, 1.0f / 2.2f), a = fabs(d);
        const float band = smoothstep(detail.y, max(3.0f * detail.y, detail.y + 1e-5f), a) * (1.0f - smoothstep(detail.z, detail.w, a));
        const float lit = smoothstep(shadow.x, shadow.y, l);
        // The colour kernel's water-like test, on the finishing input after the cast gains.
        const float3 r = max(reference.rgb, float3(0.0f)) * max(gains.rgb, float3(0.0f));
        const float redness = r.r / max(r.g + r.b, 1e-4f);
        const float top = max(r.r, max(r.g, r.b));
        const float pixelChroma = top > 1e-4f ? (top - min(r.r, min(r.g, r.b))) / top : 0.0f;
        const float chromaConfidence = smoothstep(0.55f, 0.8f, water.y);
        const float chromaMatch = smoothstep(water.y * 0.5f, max(water.y * 0.85f, water.y * 0.5f + 1e-5f), pixelChroma);
        const float waterLike = (1.0f - smoothstep(water.x, water.x + max(0.3f, water.x * 0.6f), redness))
            * (1.0f - (1.0f - chromaMatch) * chromaConfidence);
        const float3 lw = max(waterLit.rgb, float3(0.0f));
        const float waterLum = dot(lw, luma);
        const float total = r.r + r.g + r.b;
        float bright = 0.0f;
        if (waterLum > 1e-4f && total > 1e-5f) {
            const float3 diff = abs(r / total - lw / (lw.r + lw.g + lw.b));
            bright = smoothstep(1.3f, 1.8f, dot(r, luma) / waterLum) * smoothstep(0.08f, 0.2f, diff.r + diff.g + diff.b);
        }
        const float subject = 1.0f - waterLike * (1.0f - bright);
        const float weight = max(detail.x, 0.0f) * band * subject * lit;
        const float y = max(0.0f, x + weight * d);
        const float peak = max(c.r, max(c.g, c.b));
        const float3 out = c * min(pow(y, 2.2f) / l, max(1.0f, peak) / max(peak, 1e-5f));
        return all(isfinite(out)) ? float4(out, source.a) : source;
    }

    // Highlight shoulder, the last finishing step. FinishingMath.shoulder is the CPU mirror.
    // The peak is read in BT.709 primaries; the ceiling is white or the reference's own (HDR) peak.
    // shape: x = shoulder width, y and z = the overshoot range, w = the start of the pale range.
    // pale.x = the end of the pale range. Both ranges move a pixel toward white.
    [[stitchable]] float4 UnderBlueHighlightShoulder(coreimage::sample_t source, coreimage::sample_t reference, float4 shape, float4 pale) {
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

    // Luminance-only sharpening (FilterEngine.finishing). The unsharp masks run on RGB, so they also
    // sharpen colour noise. The pixel keeps its unsharpened colour and takes the sharpened luminance.
    [[stitchable]] float4 UnderBlueLumaTransfer(coreimage::sample_t base, coreimage::sample_t sharp) {
        const float3 w = float3(0.2126f, 0.7152f, 0.0722f);
        const float before = dot(base.rgb, w), after = dot(sharp.rgb, w);
        if (!(before > 1e-5f)) { return float4(sharp.rgb, base.a); }
        const float3 out = base.rgb * max(0.0f, after / before);
        return all(isfinite(out)) ? float4(out, base.a) : sharp;
    }
    """
}
