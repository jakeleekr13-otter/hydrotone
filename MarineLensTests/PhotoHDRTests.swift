import XCTest
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
@testable import MarineLens

final class PhotoHDRTests: XCTestCase {
    let context = CIContext()

    /// Blue-green water with a sun patch at 4x SDR white.
    let hdrScene: CIImage = {
        let space = FilterEngine.workingSpace
        let water = CIImage(color: CIColor(red: 0.05, green: 0.35, blue: 0.5, colorSpace: space)!).cropped(to: CGRect(x: 0, y: 0, width: 600, height: 400))
        let sun = CIImage(color: CIColor(red: 4, green: 4, blue: 3.6, colorSpace: space)!).cropped(to: CGRect(x: 400, y: 250, width: 120, height: 100))
        return sun.composited(over: water).settingContentHeadroom(4)
    }()
    func toneMapped(_ image: CIImage) -> CIImage {
        let tone = CIFilter.toneMapHeadroom()
        tone.inputImage = image
        tone.sourceHeadroom = image.contentHeadroom
        tone.targetHeadroom = 1
        return tone.outputImage!
    }
    func pixel(_ image: CIImage, _ x: CGFloat, _ y: CGFloat) -> [Float] {
        var pixel = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBAf, colorSpace: FilterEngine.workingSpace)
        return Array(pixel.prefix(3))
    }

    /// The scene saved like an iPhone HDR photo: an SDR image plus a gain map.
    func makeHDRPhoto(orientation: Int) throws -> URL {
        let hdr = hdrScene
        let sdr = toneMapped(hdr).settingProperties([kCGImagePropertyOrientation: orientation])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".heic")
        try context.writeHEIFRepresentation(of: sdr, to: url, format: .RGBA8, colorSpace: FilterEngine.photoSpace, options: [.hdrImage: hdr])
        return url
    }

    func maximum(_ image: CIImage) -> Float { measure(CIFilter.areaMaximum(), image).prefix(3).max()! }
    func average(_ image: CIImage) -> [Float] { Array(measure(CIFilter.areaAverage(), image).prefix(3)) }
    private func measure(_ filter: CIFilter & CIAreaReductionFilter, _ image: CIImage) -> [Float] {
        filter.inputImage = image
        filter.extent = image.extent
        var pixel = [Float](repeating: 0, count: 4)
        context.render(filter.outputImage!, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: FilterEngine.workingSpace)
        return pixel
    }

    func testReexpansionRestoresTheSourceBrightnessWithTheCorrection() throws {
        let original = hdrScene, tone = toneMapped(hdrScene)
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = tone
        matrix.rVector = CIVector(x: 1.3, y: 0, z: 0, w: 0)
        let corrected = matrix.outputImage!
        let hdr = try XCTUnwrap(PhotoHDR().reexpand(corrected, original: original, toneMapped: tone))
        XCTAssertEqual(hdr.contentHeadroom, 4)
        // Water: the ratio restores the source's HDR brightness, with the correction (red x1.3) kept.
        let water = pixel(hdr, 100, 100), waterSource = pixel(original, 100, 100), waterCorrected = pixel(corrected, 100, 100)
        XCTAssertEqual(water[1], waterSource[1], accuracy: 0.01)
        XCTAssertEqual(water[0] / water[1], waterCorrected[0] / waterCorrected[1], accuracy: 0.01)
        // Sun: back near 4x SDR white, never above the headroom.
        let sun = pixel(hdr, 460, 300)
        XCTAssertGreaterThan(sun[1], 3.5)
        XCTAssertLessThanOrEqual(sun.max()!, 4.001)
        XCTAssertNil(PhotoHDR().reexpand(corrected, original: tone, toneMapped: tone), "an SDR source has no HDR version")
        XCTAssertTrue(ExportCapability.photo(headroom: 4).hdrAvailable)
        XCTAssertFalse(ExportCapability.photo(headroom: 1).hdrAvailable)
    }

    /// The simulator opens every gain-map photo with headroom 1 (checked 28 Sep 2026 with a file macOS reads
    /// at 4.0), so this runs on an iPhone.
    func testHDRPhotoExportsAGainMapJPEGThatKeepsHighlightsAndTheSDRResult() async throws {
        let source = try makeHDRPhoto(orientation: 6)
        defer { try? FileManager.default.removeItem(at: source) }
        let processor = PhotoProcessor()
        let headroom = try await processor.headroom(source)
        try XCTSkipIf(headroom <= 1, "This environment reads gain-map photos as SDR")
        XCTAssertGreaterThan(headroom, 3)
        XCTAssertTrue(ExportCapability.photo(headroom: headroom).hdrAvailable)
        let settings = FilterSettings(preset: .natural)
        let sdrOutput = try await processor.export(source, settings: settings)
        let hdrOutput = try await processor.export(source, settings: settings, keepHDR: true)
        defer { TemporaryFiles.remove(sdrOutput); TemporaryFiles.remove(hdrOutput) }

        let file = try XCTUnwrap(CGImageSourceCreateWithURL(hdrOutput as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(file) as String?, UTType.jpeg.identifier)
        XCTAssertNotNil(CGImageSourceCopyAuxiliaryDataInfoAtIndex(file, 0, kCGImageAuxiliaryDataTypeISOGainMap), "ISO gain map")
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int ?? 1, 1, "orientation is baked into the pixels")

        let expanded = try XCTUnwrap(CIImage(contentsOf: hdrOutput, options: [.expandToHDR: true]))
        let base = try XCTUnwrap(CIImage(contentsOf: hdrOutput))
        XCTAssertEqual(base.extent.size, CGSize(width: 400, height: 600))
        XCTAssertGreaterThan(expanded.contentHeadroom, 3)
        XCTAssertGreaterThan(maximum(expanded), 2, "the sun keeps its headroom")
        // The SDR image inside the HDR file is the normal SDR export.
        let sdr = try XCTUnwrap(CIImage(contentsOf: sdrOutput))
        // Both SDR images read 1.141 at most on an iPhone 17 (28 Sep 2026): the same value, so no HDR leaks in.
        XCTAssertEqual(maximum(base), maximum(sdr), accuracy: 0.02)
        for (a, b) in zip(average(base), average(sdr)) { XCTAssertEqual(a, b, accuracy: 0.01) }

        // The same HDR export as a 10-bit HEIC keeps its gain map and highlights.
        let heicOutput = try await processor.export(source, settings: settings, keepHDR: true, format: .heic)
        defer { TemporaryFiles.remove(heicOutput) }
        let heicFile = try XCTUnwrap(CGImageSourceCreateWithURL(heicOutput as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(heicFile) as String?, UTType.heic.identifier)
        XCTAssertNotNil(CGImageSourceCopyAuxiliaryDataInfoAtIndex(heicFile, 0, kCGImageAuxiliaryDataTypeISOGainMap), "ISO gain map")
        let heicExpanded = try XCTUnwrap(CIImage(contentsOf: heicOutput, options: [.expandToHDR: true]))
        XCTAssertGreaterThan(heicExpanded.contentHeadroom, 3)
        XCTAssertGreaterThan(maximum(heicExpanded), 2, "the sun keeps its headroom")
    }

    func testSDRPhotoStaysSDRWhenHDRIsKept() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: source) }
        let image = CIImage(color: CIColor(red: 0.05, green: 0.35, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200))
        try context.writeJPEGRepresentation(of: image, to: source, colorSpace: FilterEngine.photoSpace)
        let processor = PhotoProcessor()
        let headroom = try await processor.headroom(source)
        XCTAssertLessThanOrEqual(headroom, 1)
        XCTAssertFalse(ExportCapability.photo(headroom: headroom).hdrAvailable)
        let output = try await processor.export(source, settings: FilterSettings(preset: .natural), keepHDR: true)
        defer { TemporaryFiles.remove(output) }
        let file = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertNil(CGImageSourceCopyAuxiliaryDataInfoAtIndex(file, 0, kCGImageAuxiliaryDataTypeISOGainMap))
    }
}
