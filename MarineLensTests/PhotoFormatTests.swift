import XCTest
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
@testable import MarineLens

final class PhotoFormatTests: XCTestCase {
    let engine = FilterEngine()
    static let captureDate = "2026:09:28 10:11:12"

    /// A small JPEG with colour detail and a capture date, like a camera photo.
    func makeSource() throws -> URL {
        let url = try TemporaryFiles.makeURL(extension: "jpg")
        let gradient = CIFilter.smoothLinearGradient()
        gradient.point0 = .zero; gradient.point1 = CGPoint(x: 96, y: 64)
        gradient.color0 = CIColor(red: 0.05, green: 0.25, blue: 0.45); gradient.color1 = CIColor(red: 0.6, green: 0.5, blue: 0.3)
        let image = gradient.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 96, height: 64))
        let cg = try XCTUnwrap(engine.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: FilterEngine.photoSpace))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: Self.captureDate]
        CGImageDestinationAddImage(destination, cg, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func properties(_ url: URL) throws -> [CFString: Any] {
        let file = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [CFString: Any])
    }

    func average(_ url: URL) throws -> [Float] {
        let image = try XCTUnwrap(CIImage(contentsOf: url))
        let filter = CIFilter.areaAverage()
        filter.inputImage = image; filter.extent = image.extent
        var pixel = [Float](repeating: 0, count: 4)
        engine.context.render(filter.outputImage!, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                              format: .RGBAf, colorSpace: FilterEngine.photoSpace)
        return Array(pixel.prefix(3))
    }

    /// Horizontal x vertical sampling factor of each component, from the JPEG frame header.
    func jpegSampling(_ url: URL) throws -> [String] {
        let bytes = [UInt8](try Data(contentsOf: url))
        var i = 2
        while i + 4 < bytes.count {
            guard bytes[i] == 0xFF else { i += 1; continue }
            let marker = bytes[i + 1], length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            if [0xC0, 0xC1, 0xC2].contains(marker) {
                return (0..<Int(bytes[i + 9])).map { k in let f = bytes[i + 11 + k * 3]; return "\(f >> 4)x\(f & 15)" }
            }
            i += 2 + length
        }
        return []
    }

    /// Below quality 1, ImageIO wrote 2x2 luma sampling (colour at half resolution).
    func testJPEGExportKeepsFullColorResolutionAndTheCaptureDate() async throws {
        let source = try makeSource()
        defer { TemporaryFiles.remove(source) }
        let output = try await PhotoProcessor().export(source, settings: FilterSettings(preset: .natural))
        defer { TemporaryFiles.remove(output) }
        XCTAssertEqual(output.pathExtension, "jpg")
        XCTAssertEqual(try jpegSampling(output), ["1x1", "1x1", "1x1"])
        let exif = try XCTUnwrap(try properties(output)[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, Self.captureDate)
    }

    func testHEICExportIsTenBitWithTheSameColorAndCaptureDate() async throws {
        try XCTSkipUnless(ExportOptions.PhotoFormat.available.contains(.heic), "This device has no HEIC encoder")
        let source = try makeSource()
        defer { TemporaryFiles.remove(source) }
        let processor = PhotoProcessor()
        let settings = FilterSettings(preset: .deep)
        let jpeg = try await processor.export(source, settings: settings)
        let heic = try await processor.export(source, settings: settings, format: .heic)
        defer { TemporaryFiles.remove(jpeg); TemporaryFiles.remove(heic) }
        XCTAssertEqual(heic.pathExtension, "heic")
        let file = try XCTUnwrap(CGImageSourceCreateWithURL(heic as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(file) as String?, UTType.heic.identifier)
        let info = try properties(heic)
        XCTAssertEqual(info[kCGImagePropertyDepth] as? Int, 10)
        XCTAssertEqual(info[kCGImagePropertyPixelWidth] as? Int, 96)
        XCTAssertEqual(info[kCGImagePropertyPixelHeight] as? Int, 64)
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(file, 0, nil))
        XCTAssertEqual(decoded.colorSpace?.name, CGColorSpace.displayP3)
        let exif = try XCTUnwrap(info[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, Self.captureDate)
        // Same correction in both formats; only the encoding differs.
        for (a, b) in zip(try average(jpeg), try average(heic)) { XCTAssertEqual(a, b, accuracy: 0.01) }
    }

    func testFormatStoreDefaultsToJPEGAndRoundTrips() {
        let name = "PhotoFormatTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PhotoFormatStore(defaults: defaults)
        XCTAssertEqual(store.load(), .jpeg)
        defaults.set("png", forKey: PhotoFormatStore.key)
        XCTAssertEqual(store.load(), .jpeg, "an unknown value falls back to JPEG")
        for format in ExportOptions.PhotoFormat.available {
            store.save(format)
            XCTAssertEqual(store.load(), format)
        }
    }

    @MainActor
    func testEditorAndBatchShareTheSavedFormat() throws {
        try XCTSkipUnless(ExportOptions.PhotoFormat.available.contains(.heic), "This device has no HEIC encoder")
        let name = "PhotoFormatTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PhotoFormatStore(defaults: defaults)
        let diagnostics = DiagnosticRecorder(directory: FileManager.default.temporaryDirectory)
        let editor = EditorModel(media: ImportedMedia(url: URL(fileURLWithPath: "/tmp/none.heic"), kind: .photo),
                                 diagnostics: diagnostics, formatStore: store)
        XCTAssertEqual(editor.options.photoFormat, .jpeg)
        editor.options.photoFormat = .heic
        XCTAssertEqual(store.load(), .heic)
        let batch = BatchModel(urls: [URL(fileURLWithPath: "/tmp/a.heic")], diagnostics: diagnostics, formatStore: store)
        XCTAssertEqual(batch.format, .heic)
        batch.format = .jpeg
        XCTAssertEqual(store.load(), .jpeg)
    }

    /// Checked by format name, so it passes in every app language.
    func testPhotoSummaryNamesTheFormat() {
        var summaries: Set<String> = []
        for range in ExportOptions.Range.allCases {
            for format in ExportOptions.PhotoFormat.allCases {
                var options = ExportOptions()
                options.range = range; options.photoFormat = format
                let summary = ExportView.photoSummary(options)
                XCTAssertTrue(summary.contains(format.name) && summary.contains(range.rawValue), summary)
                summaries.insert(summary)
            }
        }
        XCTAssertEqual(summaries.count, 4)
        XCTAssertEqual(ExportNaming.fileName(source: "DSC03545.ARW", preset: .natural, extension: "heic"), "DSC03545_MarineLens_NaturalDive.heic")
    }
}
