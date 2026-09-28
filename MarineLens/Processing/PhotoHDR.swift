import CoreImage

/// Builds the HDR version of a corrected photo for an HDR export (a JPEG with a gain map).
///
/// All colour work happens in SDR, as for every photo, so the SDR image in the file is the normal
/// export. The HDR version multiplies that result by the source's own brightness ratio: HDR source
/// over its tone-mapped SDR version. Highlights and midtones get back the brightness the tone
/// mapping took away, with the correction applied. The colour engine never sees HDR values.
final class PhotoHDR: Sendable {
    private let kernel: CIColorKernel?

    init() {
        let kernels = try? CIKernel.kernels(withMetalString: Self.metalSource)
        kernel = kernels?.first { $0.name == "MarineLensReexpand" } as? CIColorKernel
    }

    /// Nil when the source has no headroom above SDR white, or the kernel is missing.
    func reexpand(_ corrected: CIImage, original: CIImage, toneMapped: CIImage) -> CIImage? {
        let headroom = original.contentHeadroom
        guard headroom > 1, let kernel,
              let image = kernel.apply(extent: corrected.extent, arguments: [corrected, original, toneMapped, headroom]) else { return nil }
        return image.settingContentHeadroom(headroom)
    }

    // The ratio uses Rec.2020 luminance, the working space's primaries, so it changes brightness, not hue.
    // It never darkens and never exceeds the source headroom.
    private static let metalSource = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    [[stitchable]] float4 MarineLensReexpand(coreimage::sample_t corrected,
                                            coreimage::sample_t original,
                                            coreimage::sample_t toneMapped,
                                            float headroom) {
        const float3 luma = float3(0.2627f, 0.6780f, 0.0593f);
        const float limit = max(1.0f, headroom);
        const float gain = clamp((dot(original.rgb, luma) + 0.0001f) / (dot(toneMapped.rgb, luma) + 0.0001f), 1.0f, limit);
        return float4(min(corrected.rgb * gain, float3(limit)), corrected.a);
    }
    """
}

extension ExportCapability {
    /// A photo can export HDR when it has headroom above SDR white, for example an iPhone photo with a gain map.
    static func photo(headroom: Float) -> Self {
        headroom > 1
            ? Self(hdrAvailable: true, explanation: String(localized: "HDR keeps this photo’s bright highlights. The editor shows a tone-mapped SDR preview."))
            : Self(hdrAvailable: false, explanation: String(localized: "Wide color is preserved. HDR export requires an HDR photo."))
    }
}
