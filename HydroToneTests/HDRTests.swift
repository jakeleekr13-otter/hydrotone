import XCTest
import AVFoundation
import CoreImage
@testable import HydroTone

final class HDRTests: XCTestCase {
    func testHDRDetectionAndToneMappedSDRExports() async throws {
        for name in ["hlg_10bit", "pq_10bit"] {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "mov"))
            let metadata = try await MediaInspector().inspect(url)
            XCTAssertTrue(metadata.isHDR)
            XCTAssertEqual(metadata.bitDepth, 10)
            let result = try await VideoExporter().export(url: url, metadata: metadata, settings: .init(), options: .init()) { _ in }
            defer { TemporaryFiles.remove(result.url) }
            XCTAssertFalse(result.metadata.isHDR)
            XCTAssertEqual(result.metadata.transfer, AVVideoTransferFunction_ITU_R_709_2)
        }
    }
    func testHDRExportsHaveVerifiedTenBitSignalingAndHighlightRange() async throws {
        for name in ["hlg_10bit", "pq_10bit"] {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "mov"))
            let metadata = try await MediaInspector().inspect(url)
            let result = try await VideoExporter().export(url: url, metadata: metadata, settings: .init(), options: .init(range: .hdr)) { _ in }
            defer { TemporaryFiles.remove(result.url) }
            XCTAssertEqual(result.metadata.bitDepth, 10)
            XCTAssertEqual(result.metadata.dynamicRange, metadata.dynamicRange)
            XCTAssertEqual(result.metadata.primaries, AVVideoColorPrimaries_ITU_R_2020)
            XCTAssertFalse(result.metadata.hasDolbyVisionSignaling)
            let asset = AVURLAsset(url: result.url)
            let track = try await asset.loadTracks(withMediaType: .video)[0]
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
            reader.add(output); XCTAssertTrue(reader.startReading())
            defer { reader.cancelReading() }
            let buffer = try XCTUnwrap(output.copyNextSampleBuffer().flatMap { CMSampleBufferGetImageBuffer($0) })
            let image = CIImage(cvPixelBuffer: buffer)
            let maxPixel = image.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
            var values = [Float](repeating: 0, count: 4)
            FilterEngine().context.render(maxPixel, toBitmap: &values, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: FilterEngine.workingSpace)
            XCTAssertGreaterThan(values.prefix(3).max() ?? 0, 1.2, "HDR highlights were reduced to SDR for \(name)")
        }
    }
}
