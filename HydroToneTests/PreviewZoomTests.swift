import XCTest
@testable import HydroTone

final class PreviewZoomTests: XCTestCase {
    private let container = CGSize(width: 400, height: 300)

    func testFittedKeepsAspectInsideTheContainer() {
        XCTAssertEqual(PreviewZoom.fitted(CGSize(width: 4000, height: 2000), in: container), CGSize(width: 400, height: 200))
        XCTAssertEqual(PreviewZoom.fitted(CGSize(width: 1000, height: 1500), in: container), CGSize(width: 200, height: 300))
        XCTAssertEqual(PreviewZoom.fitted(.zero, in: container), .zero)
    }

    func testScaleStaysBetweenOneAndMaximum() {
        let content = PreviewZoom.fitted(CGSize(width: 4000, height: 3000), in: container)
        XCTAssertEqual(PreviewZoom(scale: 0.3).clamped(content: content, container: container).scale, 1)
        XCTAssertEqual(PreviewZoom(scale: 9).clamped(content: content, container: container).scale, PreviewZoom.maximum)
        XCTAssertEqual(PreviewZoom(scale: .nan).clamped(content: content, container: container).scale, 1)
        XCTAssertFalse(PreviewZoom(scale: 1).isZoomed)
        XCTAssertTrue(PreviewZoom(scale: 2).isZoomed)
    }

    func testPanStopsAtTheImageEdgesSoNoGapOpens() {
        // 400x300 content at 2x is 800x600, so it may move at most 200 horizontally and 150 vertically.
        let content = CGSize(width: 400, height: 300)
        let far = PreviewZoom(scale: 2, offset: CGSize(width: 900, height: -900)).clamped(content: content, container: container)
        XCTAssertEqual(far.offset, CGSize(width: 200, height: -150))
        // At 1x the image fits, so any offset snaps back to the centre.
        let fit = PreviewZoom(scale: 1, offset: CGSize(width: 50, height: 50)).clamped(content: content, container: container)
        XCTAssertEqual(fit.offset, .zero)
        // A letterboxed image (400x200 in 400x300) cannot move vertically until it is taller than the frame.
        let wide = PreviewZoom(scale: 1.2, offset: CGSize(width: 0, height: 80)).clamped(content: CGSize(width: 400, height: 200), container: container)
        XCTAssertEqual(wide.offset.height, 0)
    }
}
