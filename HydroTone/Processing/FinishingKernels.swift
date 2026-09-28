import Foundation

/// The Metal sources of the finishing kernels. FilterEngine compiles them at init; FinishingMath mirrors them.
extension FilterEngine {

    // Scene-level colour stage: cast gains, water tone, hue-gated red rebuild, mid-tone lift, luminance S-curve.
    // Every argument comes from one ColorCorrection, so video frames share one curve.
    // FinishingMath.color is the CPU mirror.
    static let colorSource = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    [[stitchable]] float4 HydroToneFinishColor(coreimage::sample_t source, float4 gains, float4 water, float4 shape, float4 red, float4 tone, float4 neutral, float4 waterLit, float4 subjectTone) {
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
        // Light removal on subjects (subjectTone.rgb): pixels that are not water-like lose part of the
        // water's colour, at their own luminance. Green and blue never fall below the pixel's red, so
        // a grey subject is not made warm. FinishingMath.color mirrors it.
        {
            float3 removed = c * mix(float3(1.0f), max(subjectTone.rgb, float3(0.0f)), 1.0f - waterLike);
            removed.gb = max(removed.gb, min(c.gb, float2(c.r)));
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
}
