// The restoration kernels. RestorationEngine loads them; RestorationMath mirrors them.
#include <CoreImage/CoreImage.h>
using namespace metal;

[[stitchable]] float4 UnderBlueRestoration(coreimage::sample_t source,
                                            coreimage::sample_t depthSample,
                                            coreimage::sample_t broadSample,
                                            float4 backscatterInfinity,
                                            float4 betaDirect,
                                            float4 betaBackscatter,
                                            float4 limits,
                                            float4 maximumGain,
                                            float4 recoverability,
                                            float4 veil) {
    const float z = clamp(depthSample.r, 0.0f, 1.0f);
    const float3 directTransmission = exp(-max(betaDirect.rgb, float3(0.0f)) * z);
    const float3 backscatterTransmission = exp(-max(betaBackscatter.rgb, float3(0.0f)) * z);
    const float3 safeTransmission = max(directTransmission, float3(max(0.01f, limits.x)));
    const float3 gain = min(1.0f / safeTransmission, max(maximumGain.rgb, float3(1.0f)));
    float3 backscatter = max(backscatterInfinity.rgb, float3(0.0f)) * (1.0f - backscatterTransmission);
    // Local veil (veil = level, lowest scale, highest scale): the veil follows the broad light
    // around the pixel (broadSample) in size, as a share of the scene's water level, and in colour.
    // RestorationMath.localVeil mirrors it.
    if (veil.x > 1e-4f) {
        const float3 luma = float3(0.2126f, 0.7152f, 0.0722f);
        const float3 broad = max(broadSample.rgb, float3(0.0f));
        const float broadLum = dot(broad, luma);
        backscatter *= clamp(broadLum / veil.x, veil.y, veil.z);
        if (broadLum > 1e-4f) { backscatter = broad * (dot(backscatter, luma) / broadLum); }
    }
    float3 restored = max(source.rgb - backscatter, float3(0.0f)) * gain;
    const float peak = max(source.r, max(source.g, source.b));
    const float highlight = smoothstep(limits.y, max(limits.y + 0.001f, limits.z), peak) * 0.8f;
    restored = mix(restored, source.rgb, highlight);
    restored = clamp(restored, float3(0.0f), float3(max(0.5f, limits.w)));
    restored = source.rgb + (restored - source.rgb) * clamp(recoverability.rgb, 0.0f, 1.0f);
    // Where veil removal leaves little light (channel sum), keep the source hue at the
    // restored level, so far water does not turn red-brown or violet.
    // RestorationMath.keepHueWhereDark mirrors it.
    const float3 lit = max(source.rgb, float3(0.0f));
    const float before = lit.r + lit.g + lit.b;
    if (before > 1e-5f) {
        const float3 now = max(restored, float3(0.0f));
        const float kept = (now.r + now.g + now.b) / before;
        restored = mix(restored, lit * kept, 1.0f - smoothstep(0.3f, 0.6f, kept));
    }
    // A blue source pixel that turned green only because the veil took nearly all its blue
    // (green/blue grew 4-8 times) keeps its source hue at the restored level.
    // RestorationMath.keepBlueFamily mirrors it.
    if (before > 1e-5f) {
        const float3 now = max(restored, float3(0.0f));
        const float blueness = smoothstep(1.0f, 1.1f, lit.b / max(max(lit.r, lit.g), 1e-4f));
        const float greenBlue = now.g / max(now.b, 1e-4f);
        const float growth = greenBlue / max(lit.g / max(lit.b, 1e-4f), 1e-4f);
        const float amount = blueness * smoothstep(1.1f, 1.4f, greenBlue) * smoothstep(4.0f, 8.0f, growth);
        restored = mix(restored, lit * ((now.r + now.g + now.b) / before), amount);
    }
    if (!all(isfinite(restored))) { restored = max(source.rgb, float3(0.0f)); }
    return float4(restored, source.a);
}

// Fine detail on the restored image: the source's detail (source - low) times the pixel's own
// restoration ratio (restoredLow / low), not 1 / transmission. See restore(_:plan:).
[[stitchable]] float4 UnderBlueRestoredDetail(coreimage::sample_t source, coreimage::sample_t low,
                                              coreimage::sample_t restoredLow, float4 maximumGain) {
    const float3 ratio = clamp(max(restoredLow.rgb, float3(0.0f)) / max(low.rgb, float3(1e-4f)),
                               float3(0.0f), max(maximumGain.rgb, float3(1.0f)));
    const float3 out = max(restoredLow.rgb + (source.rgb - low.rgb) * ratio, float3(0.0f));
    return all(isfinite(out)) ? float4(out, source.a) : restoredLow;
}

// The current and the restored result mixed per pixel: weights.x (the physical weight) times a
// ramp over depth 0 to weights.y. See RestorationEngine.combined.
[[stitchable]] float4 UnderBlueDepthBlend(coreimage::sample_t current, coreimage::sample_t depthAware,
                                          coreimage::sample_t depthSample, float4 weights) {
    const float w = weights.x * smoothstep(0.0f, max(1e-4f, weights.y), clamp(depthSample.r, 0.0f, 1.0f));
    return mix(current, depthAware, clamp(w, 0.0f, 1.0f));
}

// The local veil's broad light without the photo's subjects (SubjectMask). mode 0 gives the source
// times (1 - mask), mode 1 the weight (1 - mask) alone; RestorationEngine.restore blurs both.
[[stitchable]] float4 UnderBlueSubjectWeight(coreimage::sample_t source, coreimage::sample_t mask, float mode) {
    const float w = 1.0f - clamp(mask.r, 0.0f, 1.0f);
    return mode > 0.5f ? float4(w, w, w, 1.0f) : float4(max(source.rgb, float3(0.0f)) * w, 1.0f);
}

// Weighted blur over blurred weight, outside the subject. Inside it, and where little background
// is near, the plain broad light stays (so a subject's own restoration is unchanged).
[[stitchable]] float4 UnderBlueSubjectFreeLight(coreimage::sample_t weighted, coreimage::sample_t weight,
                                                coreimage::sample_t broad, coreimage::sample_t mask) {
    const float w = weight.r;
    const float t = smoothstep(0.02f, 0.2f, w) * (1.0f - smoothstep(0.1f, 0.6f, mask.r));
    const float3 out = mix(broad.rgb, weighted.rgb / max(w, 1e-3f), t);
    return all(isfinite(out)) ? float4(out, broad.a) : broad;
}
