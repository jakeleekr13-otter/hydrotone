import XCTest
import CoreImage
@testable import HydroTone

final class BatchTests: XCTestCase {
    let engine = FilterEngine()

    private func makePhoto(_ color: CIColor, size: CGSize = CGSize(width: 800, height: 600)) throws -> URL {
        let url = try TemporaryFiles.makeURL(extension: "heic")
        let image = CIImage(color: color).cropped(to: CGRect(origin: .zero, size: size))
        try engine.context.writeHEIFRepresentation(of: image, to: url, format: .RGBA8, colorSpace: FilterEngine.photoSpace)
        return url
    }

    func testProcessorKeepsSeparateAnalysisPerPhoto() async throws {
        let blue = try makePhoto(CIColor(red: 0.05, green: 0.45, blue: 0.75))
        let green = try makePhoto(CIColor(red: 0.10, green: 0.70, blue: 0.35))
        defer { TemporaryFiles.remove(blue); TemporaryFiles.remove(green) }
        let processor = PhotoProcessor()
        let first = try await processor.analyze(blue)
        let second = try await processor.analyze(green)
        XCTAssertNotEqual(first, second)
        // Switching back must return the first photo's analysis, not the last one analysed.
        let again = try await processor.analyze(blue)
        XCTAssertEqual(again, first)
    }

    func testThumbnailRespectsMaxPixel() async throws {
        let url = try makePhoto(CIColor(red: 0.05, green: 0.45, blue: 0.75))
        defer { TemporaryFiles.remove(url) }
        let processor = PhotoProcessor()
        let thumb = try await processor.preview(url, settings: .init(), original: false, maxPixel: BatchModel.thumbnailPixels)
        XCTAssertEqual(CGFloat(max(thumb.width, thumb.height)), BatchModel.thumbnailPixels, accuracy: 1)
    }

    @MainActor
    func testOverrideAppliesToOnePhotoAndClearsWhenEqualToShared() throws {
        let urls = [URL(fileURLWithPath: "/tmp/a.heic"), URL(fileURLWithPath: "/tmp/b.heic")]
        let model = BatchModel(urls: urls, diagnostics: DiagnosticRecorder(directory: FileManager.default.temporaryDirectory))
        let (a, b) = (model.items[0], model.items[1])
        model.setOverride(.init(preset: .deep, intensity: 1), for: a.id)
        XCTAssertEqual(model.settings(for: model.items[0]).preset, .deep)
        XCTAssertEqual(model.settings(for: model.items[1]).preset, model.shared.preset)
        model.shared.preset = .tropical
        XCTAssertEqual(model.settings(for: model.items[0]).preset, .deep, "override survives a shared change")
        XCTAssertEqual(model.settings(for: model.items[1]).preset, .tropical)
        model.setOverride(model.shared, for: a.id)
        XCTAssertNil(model.items[0].override, "an override equal to the shared look is dropped")
        XCTAssertEqual(b.id, model.items[1].id)
    }
}
