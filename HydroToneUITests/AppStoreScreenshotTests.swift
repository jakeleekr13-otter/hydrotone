import XCTest

final class AppStoreScreenshotTests: XCTestCase {
    @MainActor
    func testPhotoBeforeAndAfter() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-keychain=app-store-screenshots",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launch()

        XCTAssertTrue(app.buttons["Select Photo"].waitForExistence(timeout: 10))
        app.buttons["Select Photo"].tap()

        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        guard photo.waitForExistence(timeout: 8) else {
            XCTFail("Photo picker contents: \(app.debugDescription)")
            return
        }
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        XCTAssertTrue(app.buttons["Compare"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Deep Dive"].waitForExistence(timeout: 5))
        app.buttons["Deep Dive"].tap()
        app.sliders["Filter intensity"].adjust(toNormalizedSliderPosition: 1)
        let export = app.buttons["Export"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: export)
        waitForExpectations(timeout: 60)
        attach(app.screenshot(), named: "photo-after")

        app.buttons["Compare"].tap()
        XCTAssertEqual(app.buttons["Compare"].value as? String, "Original")
        XCTAssertTrue(app.images["Photo preview"].waitForExistence(timeout: 10))
        attach(app.screenshot(), named: "photo-before")
    }

    @MainActor
    func testVideoEditor() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-keychain=app-store-video-screenshot",
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

        XCTAssertTrue(app.buttons["Compare"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Deep Dive"].waitForExistence(timeout: 5))
        app.buttons["Deep Dive"].tap()
        app.sliders["Filter intensity"].adjust(toNormalizedSliderPosition: 1)
        let export = app.buttons["Export"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: export)
        waitForExpectations(timeout: 60)
        attach(app.screenshot(), named: "video-after")
        app.buttons["Compare"].tap()
        XCTAssertEqual(app.buttons["Compare"].value as? String, "Original")
        attach(app.screenshot(), named: "video-before")
    }

    private func attach(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
