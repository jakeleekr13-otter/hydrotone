// The HDR re-expansion kernel. PhotoHDR loads it.
// The ratio uses Rec.2020 luminance, the working space's primaries, so it changes brightness, not hue.
// It never darkens and never exceeds the source headroom.
#include <CoreImage/CoreImage.h>
using namespace metal;

[[stitchable]] float4 UnderBlueReexpand(coreimage::sample_t corrected,
                                        coreimage::sample_t original,
                                        coreimage::sample_t toneMapped,
                                        float headroom) {
    const float3 luma = float3(0.2627f, 0.6780f, 0.0593f);
    const float limit = max(1.0f, headroom);
    const float gain = clamp((dot(original.rgb, luma) + 0.0001f) / (dot(toneMapped.rgb, luma) + 0.0001f), 1.0f, limit);
    return float4(min(corrected.rgb * gain, float3(limit)), corrected.a);
}
