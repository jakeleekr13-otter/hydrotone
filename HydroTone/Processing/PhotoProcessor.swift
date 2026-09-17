import CoreImage
import ImageIO
import UniformTypeIdentifiers

actor PhotoProcessor {
    let engine = FilterEngine()
    func open(_ url: URL) throws -> CIImage {
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true, .expandToHDR: true]),
              image.extent.width > 0, image.extent.height > 0 else { throw HydroError.unreadable }
        return image
    }
    func analyze(_ url: URL) throws -> WaterAnalysis { engine.analyze(try open(url)) }
    func preview(_ url: URL, settings: FilterSettings, original: Bool) throws -> CGImage {
        try Task.checkCancellation()
        let source = engine.sdr(try open(url))
        let ratio = min(1, 1600 / max(source.extent.width, source.extent.height))
        let small = source.transformed(by: CGAffineTransform(scaleX: ratio, y: ratio))
        let result = original ? small : engine.apply(small, settings: settings)
        guard let rendered = engine.context.createCGImage(result, from: result.extent, format: .RGBA8, colorSpace: FilterEngine.photoSpace) else { throw HydroError.unreadable }
        return rendered
    }
    func export(_ url: URL, settings: FilterSettings) throws -> URL {
        try Task.checkCancellation()
        let image = engine.apply(engine.sdr(try open(url)), settings: settings)
        let target = try TemporaryFiles.makeURL(extension: "jpg")
        do {
            guard let cg = engine.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: FilterEngine.photoSpace),
                  let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw HydroError.exportFailed }
            // Bake orientation and retain capture date without copying stale thumbnails, dimensions or HDR gain maps.
            var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95, kCGImagePropertyOrientation: 1]
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let exif = original[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                var dates: [CFString: Any] = [:]
                for key in [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized] { dates[key] = exif[key] }
                properties[kCGImagePropertyExifDictionary] = dates
            }
            CGImageDestinationAddImage(destination, cg, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw HydroError.exportFailed }
            try Task.checkCancellation()
            guard let check = CGImageSourceCreateWithURL(target as CFURL, nil), CGImageSourceGetCount(check) == 1,
                  let decoded = CGImageSourceCreateImageAtIndex(check, 0, nil), decoded.width == cg.width, decoded.height == cg.height else { throw HydroError.invalidOutput }
            return target
        } catch { TemporaryFiles.remove(target); throw error }
    }
}
