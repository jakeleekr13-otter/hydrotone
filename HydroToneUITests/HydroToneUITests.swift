import XCTest

final class HydroToneUITests: XCTestCase {
    @MainActor
    func testPhotoImportPresetsCompareExportSaveAndTrialGate() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-keychain=\(UUID().uuidString)", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["Select Photo"].waitForExistence(timeout: 10))
        app.buttons["Select Photo"].tap()
        let cell = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        guard cell.waitForExistence(timeout: 8) else {
            XCTFail("Photo picker contents: \(app.debugDescription)"); return
        }
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Deep Dive"].waitForExistence(timeout: 15))
        app.buttons["Deep Dive"].tap()
        app.buttons["Compare"].tap()
        app.buttons["Compare"].tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Photo editor"; screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Export"].tap()
        XCTAssertTrue(app.staticTexts["Free trial"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 photo export. This uses your free photo."].exists)
        let exportButtons = app.buttons.matching(identifier: "Export")
        exportButtons.element(boundBy: exportButtons.count - 1).tap()
        XCTAssertTrue(app.buttons["Save to Photos"].waitForExistence(timeout: 15))
        app.buttons["Save to Photos"].tap()
        XCTAssertTrue(app.staticTexts["Saved to Photos"].waitForExistence(timeout: 10))
        app.buttons["OK"].tap()
        app.buttons["Export"].tap()
        XCTAssertTrue(app.staticTexts["One-time purchase. Every dive."].waitForExistence(timeout: 8))
    }
    @MainActor
    func testVideoImportAndLandscapeEditor() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-keychain=\(UUID().uuidString)", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["Select Video"].waitForExistence(timeout: 10))
        app.buttons["Select Video"].tap()
        let cell = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 8))
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Compare"].waitForExistence(timeout: 15))
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        app.buttons["Compare"].tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Landscape video editor"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["Export"].tap()
        XCTAssertTrue(app.staticTexts["video-trial-description"].waitForExistence(timeout: 8))
    }
    @MainActor
    func testHomeAndPaywall() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["Select Video"].waitForExistence(timeout: 10))
        app.buttons["Get Pro"].tap()
        XCTAssertTrue(app.staticTexts["One-time purchase. Every dive."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Restore Purchase"].exists)
        XCTAssertFalse(app.buttons["Subscribe"].exists)
    }
}
