import XCTest

@MainActor
final class ImprovementScreensTests: XCTestCase {
    func testSavedSpeakerSwitchAndDefaultAreReachableWithAccessibilityText() {
        let app = launchFixture()
        tapReachable(app.buttons["Change speaker"], in: app)
        XCTAssertTrue(app.navigationBars["Connect speaker"].waitForExistence(timeout: 3))
        let office = app.buttons["saved-speaker-Office"]
        reveal(office, in: app)
        XCTAssertTrue(office.isHittable)
        XCTAssertTrue(office.label.contains("May be offline"))
        let makeDefault = app.buttons["Make Office the default speaker"]
        tapReachable(makeDefault, in: app)
        XCTAssertTrue(office.label.contains("default speaker"))
        attach(app, name: "Saved speakers with accessibility text")
        tapReachable(office, in: app)
        XCTAssertTrue(app.navigationBars["Connect speaker"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Office"].waitForExistence(timeout: 3))
    }

    func testVolumeLimitAndPresetsRemainReachableWithAccessibilityText() {
        let app = launchFixture()
        tapReachable(app.buttons["Volume limit & presets"], in: app)
        XCTAssertTrue(app.navigationBars["Volume & Presets"].waitForExistence(timeout: 3))
        let limitToggle = app.switches["speaker-volume-limit-toggle"]
        guard limitToggle.waitForExistence(timeout: 3) else {
            XCTFail("Volume limit toggle is missing")
            return
        }
        reveal(limitToggle, in: app)
        // SwiftUI Form exposes an identified row and a separate native switch.
        let nativeToggle = app.switches.allElementsBoundByIndex.first {
            $0.identifier.isEmpty && $0.isHittable && limitToggle.frame.contains($0.frame)
        }
        guard let nativeToggle else {
            XCTFail("Volume limit row has no hittable native switch")
            return
        }
        nativeToggle.tap()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: limitToggle)
        guard XCTWaiter.wait(for: [enabled], timeout: 3) == .completed else {
            XCTFail("Volume limit toggle did not turn on: \(limitToggle.debugDescription)")
            return
        }
        let maximum = app.steppers["speaker-maximum-volume"]
        guard maximum.waitForExistence(timeout: 3) else {
            XCTFail("Enabled volume limit did not reveal its maximum control")
            return
        }
        reveal(maximum, in: app)
        XCTAssertTrue(maximum.isHittable)
        let increment = app.buttons["speaker-maximum-volume-Increment"]
        guard increment.waitForExistence(timeout: 3), increment.isHittable else {
            XCTFail("Maximum control has no hittable increment button")
            return
        }
        increment.tap()
        XCTAssertTrue(maximum.label.contains("61") || maximum.value as? String == "61%")
        tapReachable(app.buttons["Apply Quiet"], in: app)
        let listening = app.buttons["Apply Listening"]
        reveal(listening, in: app)
        XCTAssertTrue(listening.isHittable)
        attach(app, name: "Volume presets with accessibility text")
    }

    func testDiagnosticPreviewCopyAndShareRemainReachableWithAccessibilityText() {
        let app = launchFixture()
        tapReachable(app.buttons["Diagnostics"], in: app)
        XCTAssertTrue(app.navigationBars["Diagnostics"].waitForExistence(timeout: 3))
        tapReachable(app.buttons["Copy diagnostic report"], in: app)
        XCTAssertTrue(app.buttons["Copied"].exists)
        let report = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Ampestra iOS Diagnostics")).firstMatch
        reveal(report, in: app)
        XCTAssertTrue(report.exists)
        XCTAssertTrue(report.label.contains("Saved speaker count: 2"))
        XCTAssertFalse(report.label.contains("Living Room"))
        XCTAssertFalse(report.label.contains("192.168."))
        attach(app, name: "Diagnostic report with accessibility text")
        for _ in 0..<10 {
            if app.buttons["Share diagnostic report"].isHittable { break }
            app.swipeDown()
        }
        XCTAssertTrue(app.buttons["Share diagnostic report"].isHittable)
    }

    private func launchFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-mode", "--demo-saved-speakers", "--demo-show-settings",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<16 {
            if element.isHittable { return }
            app.swipeUp()
        }
    }

    private func tapReachable(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app)
        XCTAssertTrue(element.isHittable, "Expected control to be reachable: \(element)")
        if element.isHittable { element.tap() }
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
