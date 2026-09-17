import XCTest
import AVFoundation
import CoreImage
@testable import HydroTone

final class VideoTests: XCTestCase {
    func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "mov"))
    }
    func testSDRCodecResolutionTimingAudioAndOrientationMatrix() async throws {
        for name in ["h264_1080_30_audio", "hevc_1080_60", "portrait_audio", "hevc_4k_24_audio", "hevc_4k_60"] {
            let url = try fixture(name)
            let metadata = try await MediaInspector().inspect(url)
            let result = try await VideoExporter().export(url: url, metadata: metadata,
                settings: .init(preset: .natural, intensity: 0.8, analysis: .init(redLoss: 0.6)), options: .init()) { _ in }
            defer { TemporaryFiles.remove(result.url) }
            XCTAssertEqual(result.metadata.audioTrackCount, metadata.audioTrackCount, name)
            XCTAssertEqual(result.metadata.displaySize, metadata.displaySize, name)
            XCTAssertEqual(result.metadata.frameRate, metadata.frameRate, accuracy: 0.1, name)
            XCTAssertFalse(result.metadata.isHDR, name)
            XCTAssertEqual(result.metadata.duration, metadata.duration, accuracy: 0.06, name)
        }
    }
    func testExportedPortraitPixelsMatchSourceOrientation() async throws {
        let url = try fixture("portrait_audio")
        let metadata = try await MediaInspector().inspect(url)
        let result = try await VideoExporter().export(url: url, metadata: metadata, settings: .init(preset: .original), options: .init()) { _ in }
        defer { TemporaryFiles.remove(result.url) }
        func pixels(_ url: URL) async throws -> [Float] {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            let cg = try await generator.image(at: .zero).image
            let image = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: 16 / Double(cg.width), y: 16 / Double(cg.height)))
            var values = [Float](repeating: 0, count: 16 * 16 * 4)
            FilterEngine().context.render(image, toBitmap: &values, rowBytes: 16 * 16, bounds: CGRect(x: 0, y: 0, width: 16, height: 16), format: .RGBAf, colorSpace: FilterEngine.workingSpace)
            return values
        }
        let source = try await pixels(url), exported = try await pixels(result.url)
        let meanError = zip(source, exported).reduce(Float(0)) { $0 + abs($1.0 - $1.1) } / Float(source.count)
        XCTAssertLessThan(meanError, 0.04, "Portrait pixels are rotated or mirrored incorrectly")
    }
    func testTrialVideoStopsAtTenSecondsAndKeepsAudio() async throws {
        let url = try fixture("trial_12seconds")
        let metadata = try await MediaInspector().inspect(url)
        let result = try await VideoExporter().export(url: url, metadata: metadata, settings: .init(),
            options: .init(resolution: .hd, durationLimit: 10)) { _ in }
        defer { TemporaryFiles.remove(result.url) }
        XCTAssertEqual(result.metadata.duration, 10, accuracy: 0.04)
        XCTAssertEqual(result.frames, 300)
        XCTAssertEqual(result.metadata.audioTrackCount, 1)
    }
    func testVariablePresentationTimesArePreserved() async throws {
        let url = try fixture("variable_timing")
        let metadata = try await MediaInspector().inspect(url)
        let result = try await VideoExporter().export(url: url, metadata: metadata, settings: .init(), options: .init()) { _ in }
        defer { TemporaryFiles.remove(result.url) }
        func times(_ url: URL) async throws -> [Double] {
            let asset = AVURLAsset(url: url)
            let track = try await asset.loadTracks(withMediaType: .video)[0]
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output); XCTAssertTrue(reader.startReading())
            var times: [Double] = []
            while let sample = output.copyNextSampleBuffer() {
                // Container marker buffers carry no media samples and can have invalid/rounded time.
                if CMSampleBufferGetNumSamples(sample) > 0 { times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds) }
            }
            return times.sorted()
        }
        let source = try await times(url), exported = try await times(result.url)
        XCTAssertEqual(source.count, exported.count)
        for (a, b) in zip(source, exported) { XCTAssertEqual(a, b, accuracy: 0.0001) }
    }
    func testMidExportCancellationCleansPartialFile() async throws {
        let url = try fixture("trial_12seconds")
        let metadata = try await MediaInspector().inspect(url)
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: TemporaryFiles.directory.path)) ?? [])
        let task = Task {
            try await VideoExporter().export(url: url, metadata: metadata, settings: .init(), options: .init()) { fraction in
                if fraction > 0.1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await task.value; XCTFail("Cancellation did not stop export") } catch is CancellationError { }
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: TemporaryFiles.directory.path)) ?? [])
        XCTAssertEqual(before, after)
    }
    func testLowerResolutionIsNeverUpscaled() {
        let options = ExportOptions(resolution: .hd)
        XCTAssertEqual(options.size(for: CGSize(width: 640, height: 480)), CGSize(width: 640, height: 480))
        XCTAssertEqual(options.size(for: CGSize(width: 2160, height: 3840)), CGSize(width: 1080, height: 1920))
    }
    func testCancellationLeavesNoPartialOutput() async throws {
        let url = try fixture("hevc_4k_60")
        let metadata = try await MediaInspector().inspect(url)
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: TemporaryFiles.directory.path)) ?? [])
        let task = Task {
            try await VideoExporter().export(url: url, metadata: metadata, settings: .init(), options: .init()) { _ in }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled export succeeded") } catch is CancellationError { }
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: TemporaryFiles.directory.path)) ?? [])
        XCTAssertEqual(before, after)
    }
}
