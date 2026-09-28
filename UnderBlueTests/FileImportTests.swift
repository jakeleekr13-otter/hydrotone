import XCTest
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers
@testable import UnderBlue

final class FileImportTests: XCTestCase {
    func testFilesOffersDecodableImagesRAWAndMoviesOnly() {
        let offered = Set(FileImport.contentTypes)
        for ext in ["jpg", "heic", "png", "dng", "arw", "cr3", "nef", "mov", "mp4"] {
            XCTAssertTrue(offered.contains(UTType(filenameExtension: ext)!), ext)
        }
        XCTAssertFalse(offered.contains(.pdf))
        XCTAssertFalse(offered.contains(.mp3))
        XCTAssertEqual(FileImport.kind(of: UTType(filenameExtension: "arw")), .photo)
        XCTAssertEqual(FileImport.kind(of: .quickTimeMovie), .video)
        XCTAssertNil(FileImport.kind(of: .pdf))
    }

    /// Uses a portrait Sony RAW from DeveloperMedia, which is not in git. Skips when it is missing.
    func testRAWOpensUprightAtTheStandardRendering() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DeveloperMedia/bomikim/DSC03545.ARW")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "Developer RAW sample missing")
        let opened = try await PhotoProcessor().open(url)
        XCTAssertEqual(opened.extent.size, CGSize(width: 3648, height: 5472), "EXIF orientation 8 must be applied")
        XCTAssertLessThanOrEqual(opened.contentHeadroom, 1)
        // The embedded preview (what CIImage(contentsOf:) returns on iOS) is 1080 × 1616.
        let preview = try XCTUnwrap(CIImage(contentsOf: url, options: [.applyOrientationProperty: true]))
        XCTAssertLessThan(preview.extent.width, opened.extent.width)
        // Not the darker HDR-expanded and tone-mapped rendering: the mean stays near the standard rendering.
        let expanded = FilterEngine().sdr(try XCTUnwrap(CIImage(contentsOf: url, options: [.expandToHDR: true])))
        // Measured on this file: green 0.431 opened, 0.332 expanded.
        XCTAssertGreaterThan(mean(opened)[1], mean(expanded)[1] + 0.05)
    }

    private func mean(_ image: CIImage) -> [Float] {
        let average = CIFilter.areaAverage()
        average.inputImage = image
        average.extent = image.extent
        var pixel = [Float](repeating: 0, count: 4)
        CIContext().render(average.outputImage!, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBAf, colorSpace: FilterEngine.photoSpace)
        return pixel
    }

    func testInboxOpensTheNewestCompleteShareInOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InboxTest-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let older = try SharedInbox.beginShare(at: root, now: now.addingTimeInterval(-60))
        try Data("x".utf8).write(to: older.appendingPathComponent(SharedInbox.fileName(index: 0, original: "old.jpg")))
        try SharedInbox.finish(older)
        let newer = try SharedInbox.beginShare(at: root, now: now)
        for (index, name) in ["IMG_2.HEIC", "DSC03545.ARW", "IMG_1.HEIC"].enumerated() {
            try Data("x".utf8).write(to: newer.appendingPathComponent(SharedInbox.fileName(index: index, original: name)))
        }
        try SharedInbox.finish(newer)
        let stale = try SharedInbox.beginShare(at: root, now: now.addingTimeInterval(-2 * 60 * 60))
        let running = try SharedInbox.beginShare(at: root, now: now)

        let share = try XCTUnwrap(SharedInbox.takeNewest(at: root, now: now))
        XCTAssertEqual(share.items.map(\.originalName), ["IMG_2.HEIC", "DSC03545.ARW", "IMG_1.HEIC"])
        let left = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).map(\.lastPathComponent)
        XCTAssertEqual(Set(left), [share.folder.lastPathComponent, running.lastPathComponent],
                       "the older share and the abandoned partial one are removed; a running share stays")
        XCTAssertFalse(left.contains(stale.lastPathComponent))
        SharedInbox.remove(share.folder)
        XCTAssertNil(SharedInbox.takeNewest(at: root, now: now), "a share still being written is never opened")
    }

    func testSharedItemNamesKeepARealExtension() {
        let heic = UTType.heic
        XCTAssertEqual(SharedInbox.originalName(suggested: "IMG_1234", file: URL(fileURLWithPath: "/t/abc.HEIC"), type: heic), "IMG_1234.HEIC")
        XCTAssertEqual(SharedInbox.originalName(suggested: "IMG_1234.HEIC", file: URL(fileURLWithPath: "/t/abc.HEIC"), type: heic), "IMG_1234.HEIC")
        XCTAssertEqual(SharedInbox.originalName(suggested: nil, file: URL(fileURLWithPath: "/t/DSC0001.ARW"), type: .rawImage), "DSC0001.ARW")
        XCTAssertEqual(SharedInbox.originalName(suggested: "a/b", file: nil, type: .png), "a_b.png")
        XCTAssertEqual(SharedInbox.originalName(suggested: nil, file: nil, type: .jpeg), "Shared.jpeg")
    }
}
