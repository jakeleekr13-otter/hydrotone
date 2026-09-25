import XCTest

final class ExportSheetTests: XCTestCase {
    @MainActor
    func testVideoExportSheetShowsActionAndEstimates() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-keychain=export-sheet",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launch()

        XCTAssertTrue(app.buttons["Select Video"].waitForExistence(timeout: 10))
        app.buttons["Select Video"].tap()
        let video = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        guard video.waitForExistence(timeout: 8) else {
            XCTFail("Video picker contents: \(app.debugDescription)")
            return
        }
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let export = app.buttons["Export"]
        XCTAssertTrue(export.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: export)
        waitForExpectations(timeout: 60)
        attach(app.screenshot(), named: "editor-controls")
        export.tap()

        let confirm = app.buttons["export-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(confirm.isHittable, "Export action must be visible without scrolling")
        attach(app.screenshot(), named: "export-sheet-estimating")

        let estimate = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '~'")).firstMatch
        XCTAssertTrue(estimate.waitForExistence(timeout: 120), "No export-time estimate appeared")
        sleep(5)
        attach(app.screenshot(), named: "export-sheet-estimates")
    }

    private func attach(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
