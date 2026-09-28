import XCTest

/// The Custom preset: its sliders replace intensity, keep their values across launches, and Reset clears them.
final class CustomPresetUITests: XCTestCase {
    private let names = ["Brightness", "Contrast", "Saturation", "Clarity", "Temperature"]

    @MainActor
    func testPhotoCustomSlidersPersistAndReset() throws {
        var app = launch()
        try open(app, button: "Select Photo")
        selectCustom(app)
        for name in names { XCTAssertTrue(app.sliders[name].exists, "missing slider \(name)") }
        XCTAssertFalse(app.sliders["Filter intensity"].exists)
        // Start from zero in case an earlier run left values behind.
        if app.buttons["Reset"].isEnabled { app.buttons["Reset"].tap() }
        XCTAssertFalse(app.buttons["Reset"].isEnabled)
        app.sliders["Brightness"].adjust(toNormalizedSliderPosition: 0.8)
        let value = app.sliders["Brightness"].value as? String ?? ""
        XCTAssertTrue(value.hasPrefix("+"), "Brightness value \(value)")
        XCTAssertTrue(app.buttons["Reset"].isEnabled)
        attach(app, "custom-photo")

        // The one saved slot comes back after a relaunch.
        app.terminate()
        app = launch()
        try open(app, button: "Select Photo")
        selectCustom(app)
        XCTAssertEqual(app.sliders["Brightness"].value as? String, value)
        app.buttons["Reset"].tap()
        XCTAssertEqual(app.sliders["Brightness"].value as? String, "0")
        XCTAssertFalse(app.buttons["Reset"].isEnabled)
        // Built-in presets keep the intensity slider.
        app.buttons["Deep Dive"].tap()
        XCTAssertTrue(app.sliders["Filter intensity"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.sliders["Brightness"].exists)
    }

    @MainActor
    func testVideoCustomSliders() throws {
        let app = launch()
        try open(app, button: "Select Video")
        selectCustom(app)
        for name in names { XCTAssertTrue(app.sliders[name].exists, "missing slider \(name)") }
        XCTAssertFalse(app.sliders["Filter intensity"].exists)
        app.sliders["Temperature"].adjust(toNormalizedSliderPosition: 0.25)
        XCTAssertTrue((app.sliders["Temperature"].value as? String ?? "").hasPrefix("-"))
        attach(app, "custom-video")
        app.buttons["Reset"].tap()
        XCTAssertEqual(app.sliders["Temperature"].value as? String, "0")
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-keychain=custom-preset", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    @MainActor private func open(_ app: XCUIApplication, button: String) throws {
        XCTAssertTrue(app.buttons[button].waitForExistence(timeout: 10))
        app.buttons[button].tap()
        let cell = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        if !cell.waitForExistence(timeout: 8), app.staticTexts["No Videos"].exists { throw XCTSkip("No videos in this library") }
        guard cell.exists else { XCTFail("Picker contents: \(app.debugDescription)"); return }
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // Wait until the media is open, so the controls act on a loaded editor.
        let export = app.buttons["Export"]
        XCTAssertTrue(export.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: export)
        waitForExpectations(timeout: 60)
    }

    /// Custom is the last tile, so on a narrow screen the strip may need a swipe first.
    @MainActor private func selectCustom(_ app: XCUIApplication) {
        let custom = app.buttons["Custom"]
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        if custom.frame.maxX > app.frame.maxX { app.buttons["Tropical"].swipeLeft() }
        custom.tap()
        XCTAssertTrue(app.sliders["Brightness"].waitForExistence(timeout: 5))
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
