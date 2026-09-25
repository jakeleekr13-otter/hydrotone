import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import HydroTone

final class PhotoTests: XCTestCase {
    let engine = FilterEngine()
    func testPresetListStaysCompactAndDistinct() {
        XCTAssertEqual(DivePreset.allCases, [.original, .natural, .tropical, .deep, .custom])
    }
    func pixel(_ image: CIImage) -> [Float] {
        var result = [Float](repeating: 0, count: 4)
        engine.context.render(image, toBitmap: &result, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: FilterEngine.workingSpace)
        return result
    }
    func testIntensityEndpointsAndInterpolation() {
        let image = CIImage(color: CIColor(red: 0.08, green: 0.5, blue: 0.7)).cropped(to: CGRect(x: 0, y: 0, width: 48, height: 48))
        let analysis = engine.analyze(image)
        XCTAssertGreaterThan(analysis.redLoss, 0.5)
        let original = pixel(image)
        let zero = pixel(engine.apply(image, settings: .init(preset: .deep, intensity: 0, analysis: analysis)))
        let full = pixel(engine.apply(image, settings: .init(preset: .deep, intensity: 1, analysis: analysis)))
        let half = pixel(engine.apply(image, settings: .init(preset: .deep, intensity: 0.5, analysis: analysis)))
        for i in 0..<3 {
            XCTAssertEqual(zero[i], original[i], accuracy: 0.001)
            XCTAssertEqual(half[i], (original[i] + full[i]) / 2, accuracy: 0.003)
        }
        // Full strength must change the image, but uniform blue water gets no added red:
        // red added to blue water is what turned corrected water violet.
        XCTAssertGreaterThan(abs(full[0] - original[0]) + abs(full[1] - original[1]) + abs(full[2] - original[2]), 0.02)
        XCTAssertGreaterThan(full[2], full[0])
    }
    func testNeutralWhiteAndBlackStayNeutral() {
        for level: CGFloat in [0, 0.5, 1] {
            let source = CIImage(color: CIColor(red: level, green: level, blue: level)).cropped(to: CGRect(x: 0, y: 0, width: 48, height: 48))
            let corrected = pixel(engine.apply(source, settings: .init(preset: .deep, intensity: 1, analysis: engine.analyze(source))))
            XCTAssertEqual(corrected[0], corrected[1], accuracy: 0.002)
            XCTAssertEqual(corrected[1], corrected[2], accuracy: 0.002)
        }
    }
    func testDeepDiveKeepsCyanWaterBlueDominant() {
        let source = CIImage(color: CIColor(red: 0.05, green: 0.50, blue: 0.60))
            .cropped(to: CGRect(x: 0, y: 0, width: 48, height: 48))
        let analysis = WaterAnalysis(redLoss: 0.9, cyanDominance: 0.9, exposure: 0,
                                     contrast: 0.12, saturation: 0.75)
        let corrected = pixel(engine.apply(source, settings: .init(preset: .deep, intensity: 1,
                                                                    analysis: analysis)))
        XCTAssertGreaterThan(corrected[2], corrected[0])
    }
    /// Mean OKLab hue and chroma of a corrected scene: a water field with a small warmer subject.
    private func correctedWater(_ water: CIColor, preset: DivePreset = .natural) -> SIMD3<Float> {
        let field = CIImage(color: water).cropped(to: CGRect(x: 0, y: 0, width: 48, height: 48))
        let subject = CIImage(color: CIColor(red: 0.35, green: 0.3, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 12, height: 12))
        let image = subject.composited(over: field)
        let settings = FilterSettings(preset: preset, intensity: 1, analysis: engine.analyze(image))
        var result = [Float](repeating: 0, count: 4)
        engine.context.render(engine.apply(image, settings: settings), toBitmap: &result, rowBytes: 16,
                              bounds: CGRect(x: 40, y: 40, width: 1, height: 1), format: .RGBAf, colorSpace: FilterEngine.workingSpace)
        return ColorCorrection.oklch(SIMD3(result[0], result[1], result[2]))
    }
    func testNeonBlueWaterIsCalmedAndNeverTurnsIndigo() {
        let source = ColorCorrection.oklch(SIMD3(0.039, 0.010, 0.804))
        for preset in [DivePreset.natural, .tropical, .deep] {
            let out = correctedWater(CIColor(red: 0.039, green: 0.010, blue: 0.804, colorSpace: FilterEngine.workingSpace)!, preset: preset)
            XCTAssertLessThan(out.z, 266, "\(preset)")
            XCTAssertGreaterThan(out.z, 215, "\(preset)")
            XCTAssertLessThan(out.y, source.y * 0.7, "\(preset)")
        }
    }
    func testTealWaterMovesTowardCyanBlue() {
        let teal = SIMD3<Float>(0.03, 0.26, 0.29)
        let out = correctedWater(CIColor(red: 0.03, green: 0.26, blue: 0.29, colorSpace: FilterEngine.workingSpace)!)
        XCTAssertGreaterThan(out.z, ColorCorrection.oklch(teal).z + 10)
        XCTAssertLessThan(out.z, 266)
    }
    func testPresetSymbolsAreDistinct() {
        XCTAssertEqual(Set(DivePreset.allCases.map(\.symbolName)).count, DivePreset.allCases.count)
    }
    func testHEICImportAndPhotoPreviewExportMatch() async throws {
        let input = try TemporaryFiles.makeURL(extension: "heic")
        defer { TemporaryFiles.remove(input) }
        let image = CIImage(color: CIColor(red: 0.08, green: 0.5, blue: 0.7)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 90))
        try engine.context.writeHEIFRepresentation(of: image, to: input, format: .RGBA8, colorSpace: FilterEngine.photoSpace)
        let processor = PhotoProcessor()
        let analysis = try await processor.analyze(input)
        let settings = FilterSettings(preset: .deep, intensity: 0.75, analysis: analysis)
        let preview = try await processor.preview(input, settings: settings, original: false)
        let output = try await processor.export(input, settings: settings)
        defer { TemporaryFiles.remove(output) }
        let saved = try XCTUnwrap(CIImage(contentsOf: output))
        let previewPixel = pixel(CIImage(cgImage: preview)), savedPixel = pixel(saved)
        for i in 0..<3 { XCTAssertEqual(previewPixel[i], savedPixel[i], accuracy: 0.02) }
    }
    func testPortraitJPEGExportBakesOrientationAndPreservesColorProfile() async throws {
        let url = try TemporaryFiles.makeURL(extension: "jpg")
        defer { TemporaryFiles.remove(url) }
        let image = CIImage(color: CIColor(red: 0.15, green: 0.5, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 40))
        let cg = try XCTUnwrap(engine.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: FilterEngine.photoSpace))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let processor = PhotoProcessor()
        let output = try await processor.export(url, settings: .init())
        defer { TemporaryFiles.remove(output) }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let result = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(result.width, 40); XCTAssertEqual(result.height, 80)
        XCTAssertEqual(result.colorSpace?.name, CGColorSpace.displayP3)
    }
}
