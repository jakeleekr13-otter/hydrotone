import XCTest

/// Needs a Pro device or account: the picker allows several photos only for Pro.
final class BatchFlowTests: XCTestCase {
    @MainActor
    func testBatchSelectCompareOverrideAndSave() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-keychain=batch-flow", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        addUIInterruptionMonitor(withDescription: "Photos access") { alert in
            for label in ["Allow Full Access", "Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap(); return true
            }
            return false
        }
        app.launch()

        let select = app.buttons["Select Photos"]
        guard select.waitForExistence(timeout: 10) else {
            throw XCTSkip("Not Pro: Home shows no multi-photo picker")
        }
        select.tap()
        let cells = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 15), "Picker contents: \(app.debugDescription)")
        cells.element(boundBy: 0).tap()
        cells.element(boundBy: 1).tap()
        let add = ["Add", "Done"].map { app.buttons[$0] }.first { $0.exists }
        guard let add else { XCTFail("No picker confirm button: \(app.debugDescription)"); return }
        add.tap()

        let saveAll = app.buttons["Save All (2)"]
        XCTAssertTrue(saveAll.waitForExistence(timeout: 60), "Batch screen did not load 2 photos")
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: saveAll)
        waitForExpectations(timeout: 60)
        attach(app, "1-grid")

        app.buttons["Compare"].tap()
        attach(app, "2-grid-original")
        app.buttons["Compare"].tap()

        app.buttons["Deep Dive"].firstMatch.tap()
        sleep(2)
        attach(app, "3-grid-deep")

        // Open the first photo, swipe to the second, give it its own look, then reset it.
        app.descendants(matching: .any).matching(identifier: "Corrected").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["1 of 2"].waitForExistence(timeout: 10))
        app.swipeLeft()
        XCTAssertTrue(app.staticTexts["2 of 2"].waitForExistence(timeout: 5))
        app.buttons["Tropical"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Reset to batch settings"].waitForExistence(timeout: 5))
        sleep(2)
        attach(app, "4-detail-override")
        app.buttons["Reset to batch settings"].tap()
        XCTAssertFalse(app.buttons["Reset to batch settings"].exists)
        app.buttons["Tropical"].firstMatch.tap()
        app.buttons["Done"].tap()

        saveAll.tap()
        app.tap() // lets the interruption monitor handle a Photos permission alert
        let summary = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Saved to Photos'")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 120), "No save summary")
        attach(app, "5-saved")
        XCTAssertEqual(summary.label, "Saved to Photos: 2")
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
