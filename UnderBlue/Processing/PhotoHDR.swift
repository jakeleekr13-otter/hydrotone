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
        kernel = MetalKernels.color("UnderBlueReexpand")
    }

    /// Nil when the source has no headroom above SDR white, or the kernel is missing.
    func reexpand(_ corrected: CIImage, original: CIImage, toneMapped: CIImage) -> CIImage? {
        let headroom = original.contentHeadroom
        guard headroom > 1, let kernel,
              let image = kernel.apply(extent: corrected.extent, arguments: [corrected, original, toneMapped, headroom]) else { return nil }
        return image.settingContentHeadroom(headroom)
    }
}

extension ExportCapability {
    /// A photo can export HDR when it has headroom above SDR white, for example an iPhone photo with a gain map.
    static func photo(headroom: Float) -> Self {
        headroom > 1
            ? Self(hdrAvailable: true, explanation: String(localized: "HDR keeps this photo’s bright highlights. The editor shows a tone-mapped SDR preview."))
            : Self(hdrAvailable: false, explanation: String(localized: "Wide color is preserved. HDR export requires an HDR photo."))
    }
}
