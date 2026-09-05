import XCTest

/// Run this suite once in each simulator appearance. Screenshots retain the
/// Dynamic Type category; the result bundle identifies the device and appearance.
@MainActor
final class AccessibilityMatrixTests: XCTestCase {
    private enum TextSize: String, CaseIterable {
        case large = "UICTContentSizeCategoryL"
        case extraExtraExtraLarge = "UICTContentSizeCategoryXXXL"
        case accessibilityMedium = "UICTContentSizeCategoryAccessibilityM"
        case accessibilityExtraExtraExtraLarge = "UICTContentSizeCategoryAccessibilityXXXL"
    }

    func testRemoteControlsAcrossDynamicTypeSizes() {
        var previousReadingHeight: CGFloat = 0
        for size in TextSize.allCases {
            XCTContext.runActivity(named: "Portrait remote: \(size.rawValue)") { _ in
                let app = launchFixture(size: size)
                defer { app.terminate() }
                attach(app, name: "Remote top", size: size)
                let reading = app.descendants(matching: .any)["volume-reading"].firstMatch
                XCTAssertGreaterThanOrEqual(reading.frame.height, previousReadingHeight)
                previousReadingHeight = reading.frame.height

                tapReachable(app.buttons["Volume down"], in: app)
                assertVolume(37, in: app)
                tapReachable(app.buttons["Mute"], in: app)
                assertVolume(0, in: app)
                tapReachable(app.buttons["Restore volume"], in: app)
                assertVolume(37, in: app)
                tapReachable(app.buttons["Volume up"], in: app)
                assertVolume(42, in: app)
                attach(app, name: "Volume controls", size: size)

                tapReachable(app.buttons["Pause"], in: app)
                XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3))
                tapReachable(app.buttons["Play"], in: app)
                XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 3))

                let source = app.buttons["speaker-source-control"]
                tapReachable(source, in: app)
                let television = app.buttons["TV"]
                XCTAssertTrue(television.waitForExistence(timeout: 3))
                attach(app, name: "Source choices", size: size)
                tapReachable(television, in: app)
                waitForValue("Source, TV", key: "label", on: source)
                XCTAssertTrue(app.navigationBars["Source"].waitForNonExistence(timeout: 3))
                attach(app, name: "Playback and source", size: size)
            }
        }
    }

    func testSettingsAndConnectionAtDefaultAndLargestText() {
        for size in [TextSize.large, .accessibilityExtraExtraExtraLarge] {
            XCTContext.runActivity(named: "Settings and connection: \(size.rawValue)") { _ in
                let app = launchFixture(size: size, arguments: ["--demo-show-settings"])
                defer { app.terminate() }
                XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
                attach(app, name: "Settings", size: size)
                tapReachable(app.buttons["Volume limit & presets"], in: app)
                XCTAssertTrue(app.navigationBars["Volume & Presets"].waitForExistence(timeout: 3))
                XCTAssertTrue(app.switches["speaker-volume-limit-toggle"].exists)
                tapReachable(app.buttons["Apply Quiet"], in: app)
                attach(app, name: "Volume presets", size: size)
                app.navigationBars.buttons["Settings"].tap()

                tapReachable(app.buttons["How to use Siri"], in: app)
                XCTAssertTrue(app.navigationBars["Siri & Shortcuts"].waitForExistence(timeout: 3))
                let command = app.staticTexts["siri-command-source-tv"]
                reveal(command, in: app)
                XCTAssertEqual(command.label, "“Set speakers to TV with Ampestra”")
                attach(app, name: "Siri help", size: size)
                app.navigationBars.buttons["Settings"].tap()
                app.navigationBars["Settings"].buttons["Done"].tap()

                // Reopening resets the form to its first section, keeping the
                // transition check independent of its previous scroll position.
                tapReachable(app.buttons["Settings"], in: app)
                XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
                tapReachable(app.buttons["Change speaker"], in: app)
                let connection = app.navigationBars["Connect speaker"]
                XCTAssertTrue(connection.waitForExistence(timeout: 3))
                attach(app, name: "Connect speaker", size: size)

                let office = app.buttons["saved-speaker-Office"]
                reveal(office, in: app)
                XCTAssertTrue(office.isHittable)
                XCTAssertTrue(office.label.contains("May be offline"))
                attach(app, name: "Saved speakers", size: size)

                let address = app.textFields["manual-speaker-address"]
                reveal(address, in: app)
                XCTAssertTrue(address.isHittable)
                XCTAssertEqual(address.label, "Speaker address")
                XCTAssertTrue(app.buttons["Connect to manual address"].exists)
                XCTAssertFalse(app.buttons["Connect to manual address"].isEnabled)
                attach(app, name: "Manual connection", size: size)
                connection.buttons["Done"].tap()
                XCTAssertTrue(connection.waitForNonExistence(timeout: 3))
                XCTAssertTrue(app.scrollViews["remote-controls-scroll"].exists)
            }
        }
    }

    func testLargestTextStandbyAndPowerOnInLandscape() {
        let size = TextSize.accessibilityExtraExtraExtraLarge
        let app = launchFixture(size: size, arguments: ["--demo-standby"])
        defer {
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                return frame.width > frame.height
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 5), .completed)
        attach(app, name: "Landscape standby top", size: size)

        let power = app.buttons["Power on"]
        reveal(power, in: app)
        XCTAssertTrue(power.isHittable)
        XCTAssertTrue(power.isEnabled)
        XCTAssertFalse(app.buttons["Volume up"].exists)
        attach(app, name: "Landscape standby action", size: size)
        tapReachable(power, in: app)
        let volumeUp = app.buttons["Volume up"]
        XCTAssertTrue(volumeUp.waitForExistence(timeout: 3))
        tapReachable(volumeUp, in: app)
        assertVolume(47, in: app)
        attach(app, name: "Landscape powered on", size: size)
    }

    func testSystemAccessibilitySemantics() throws {
        // A launch-time text-size override prevents the system audit from
        // changing the category itself. The interaction matrix uses overrides;
        // this audit deliberately follows the simulator's actual preference.
        let app = XCUIApplication()
        app.launchArguments = ["--demo-mode", "--demo-saved-speakers"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.scrollViews["remote-controls-scroll"].waitForExistence(timeout: 5))
        try auditSemantics(app)
        app.terminate()
        app.launchArguments += ["--demo-show-settings"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        try auditSemantics(app)
    }

    private func auditSemantics(_ app: XCUIApplication) throws {
        // Full visual audits are reviewed alongside screenshots (see the QA
        // report). Keep semantic and target-size checks as strict regressions.
        try app.performAccessibilityAudit(for: [
            .elementDetection, .hitRegion, .sufficientElementDescription, .trait,
        ])
    }

    func testMaximumVolumeAtLargestText() {
        let size = TextSize.accessibilityExtraExtraExtraLarge
        let app = launchFixture(size: size)
        defer { app.terminate() }
        let slider = app.sliders["Speaker volume"]
        reveal(slider, in: app)
        slider.adjust(toNormalizedSliderPosition: 1)
        // XCTest synthesizes a drag and can stop just shy of the endpoint on
        // iPad. The step control also verifies the 100% clamp deterministically.
        tapReachable(app.buttons["Volume up"], in: app)
        assertVolume(100, in: app)
        let reading = app.descendants(matching: .any)["volume-reading"].firstMatch
        XCTAssertLessThanOrEqual(reading.frame.width, app.windows.firstMatch.frame.width - 48)
        attach(app, name: "Three-digit volume at largest text", size: size)
    }

    func testReducedMotionAndTransparency() throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        if !settings.navigationBars["Accessibility"].exists {
            tapReachable(settings.buttons["Accessibility"].firstMatch, in: settings)
        }
        tapReachable(settings.buttons["MOTION_TITLE"], in: settings)
        let motion = settings.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Reduce Motion")).firstMatch
        XCTAssertTrue(motion.waitForExistence(timeout: 3), settings.debugDescription)
        let motionWasEnabled = motion.value as? String == "1"
        setSystemSwitch(motion, enabled: true)
        settings.navigationBars.buttons["Accessibility"].tap()
        tapReachable(settings.buttons["DISPLAY_AND_TEXT"], in: settings)
        let transparency = settings.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Reduce Transparency")).firstMatch
        reveal(transparency, in: settings)
        XCTAssertTrue(transparency.exists, settings.debugDescription)
        let transparencyWasEnabled = transparency.value as? String == "1"
        setSystemSwitch(transparency, enabled: true)
        defer {
            settings.activate()
            setSystemSwitch(transparency, enabled: transparencyWasEnabled)
            settings.navigationBars.buttons["Accessibility"].tap()
            tapReachable(settings.buttons["MOTION_TITLE"], in: settings)
            setSystemSwitch(motion, enabled: motionWasEnabled)
            settings.navigationBars.buttons["Accessibility"].tap()
            settings.terminate()
        }
        let app = launchFixture(size: .accessibilityExtraExtraExtraLarge)
        defer { app.terminate() }
        tapReachable(app.buttons["Volume up"], in: app)
        assertVolume(47, in: app)
        tapReachable(app.buttons["Mute"], in: app)
        assertVolume(0, in: app)
        tapReachable(app.buttons["Restore volume"], in: app)
        assertVolume(47, in: app)
        attach(app, name: "Reduced motion and transparency", size: .accessibilityExtraExtraExtraLarge)
        try auditSemantics(app)
    }

    private func setSystemSwitch(_ element: XCUIElement, enabled: Bool) {
        let expected = enabled ? "1" : "0"
        for _ in 0..<3 {
            if element.value as? String == expected { return }
            // iOS 27 exposes the whole Settings row as the switch. The trailing
            // control, rather than the centre of the label, changes its value.
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            let changed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", expected), object: element
            )
            if XCTWaiter.wait(for: [changed], timeout: 1) == .completed { return }
        }
        waitForValue(expected, key: "value", on: element)
    }

    private func launchFixture(size: TextSize, arguments: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "--demo-mode", "--demo-saved-speakers",
            "-UIPreferredContentSizeCategoryName", size.rawValue,
        ] + arguments
        app.launch()
        let initialScreen = arguments.contains("--demo-show-settings")
            ? app.navigationBars["Settings"]
            : app.scrollViews["remote-controls-scroll"]
        XCTAssertTrue(initialScreen.waitForExistence(timeout: 5))
        return app
    }

    private func assertVolume(_ volume: Int, in app: XCUIApplication) {
        waitForValue("\(volume) percent", key: "value", on: app.sliders["Speaker volume"])
    }

    private func waitForValue(_ value: String, key: String, on element: XCUIElement) {
        let expected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "%K == %@", key, value), object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 3), .completed)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<16 {
            if element.isHittable { return }
            app.swipeUp()
        }
    }

    private func tapReachable(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app)
        XCTAssertTrue(element.isHittable, "Expected a reachable control: \(element)")
        if element.isHittable { element.tap() }
    }

    private func attach(_ app: XCUIApplication, name: String, size: TextSize) {
        // Screen capture preserves the rotated iPad surface; app.screenshot()
        // can retain portrait bounds immediately after a landscape transition.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(name) — \(size.rawValue)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
