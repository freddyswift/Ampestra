import AppIntentsTesting
import XCTest

final class AppIntentMetadataTests: XCTestCase {
    private let bundleIdentifier = "com.freddyswift.ampestra"

    func testPromotedSpeakerIntentParametersAreExported() throws {
        let definitions = IntentDefinitions(bundleIdentifier: bundleIdentifier)

        let direction = definitions.enums["SpeakerVolumeDirection"].makeCase("up")
        let adjustVolume = definitions.intents["AdjustSpeakerVolumeIntent"].makeIntent(
            direction: direction
        )
        let configuredDirection: AnyAppEnum = try adjustVolume.direction
        XCTAssertEqual(configuredDirection.rawValue, "up")

        let setVolume = definitions.intents["SetSpeakerVolumeIntent"].makeIntent(volume: 35)
        let configuredVolume: Int = try setVolume.volume
        XCTAssertEqual(configuredVolume, 35)

        let power = definitions.enums["SpeakerPowerState"].makeCase("on")
        let setPower = definitions.intents["SetSpeakerPowerIntent"].makeIntent(state: power)
        let configuredPower: AnyAppEnum = try setPower.state
        XCTAssertEqual(configuredPower.rawValue, "on")

        let source = definitions.enums["SpeakerIntentSource"].makeCase("tv")
        let setSource = definitions.intents["SetSpeakerSourceIntent"].makeIntent(source: source)
        let configuredSource: AnyAppEnum = try setSource.source
        XCTAssertEqual(configuredSource.rawValue, "tv")

        let mute = definitions.enums["SpeakerMuteState"].makeCase("mute")
        let setMute = definitions.intents["SetSpeakerMuteIntent"].makeIntent(state: mute)
        let configuredMute: AnyAppEnum = try setMute.state
        XCTAssertEqual(configuredMute.rawValue, "mute")

        let playback = definitions.enums["SpeakerPlaybackAction"].makeCase("pause")
        let controlPlayback = definitions.intents["ControlSpeakerPlaybackIntent"].makeIntent(
            action: playback
        )
        let configuredPlayback: AnyAppEnum = try controlPlayback.action
        XCTAssertEqual(configuredPlayback.rawValue, "pause")
    }

    func testStatusIntentRemainsAvailableForCustomShortcuts() {
        let definitions = IntentDefinitions(bundleIdentifier: bundleIdentifier)
        let status = definitions.intents["GetSpeakerStatusIntent"]

        XCTAssertEqual(status.bundleIdentifier, bundleIdentifier)
        XCTAssertEqual(status.identifier, "GetSpeakerStatusIntent")
    }

    func testWidgetControlIntentsAreExportedByHostApp() {
        let definitions = IntentDefinitions(bundleIdentifier: bundleIdentifier)

        for identifier in [
            "LowerSpeakerVolumeWidgetIntent",
            "RaiseSpeakerVolumeWidgetIntent",
            "MuteSpeakerWidgetIntent",
        ] {
            let intent = definitions.intents[identifier]
            XCTAssertEqual(intent.bundleIdentifier, bundleIdentifier)
            XCTAssertEqual(intent.identifier, identifier)
        }
    }

    @MainActor
    func testRemoteControlsRemainReachableInLandscapeWithLargeTextAndError() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-mode", "--demo-error",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = NSPredicate { _, _ in
            app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height
        }
        _ = expectation(for: landscape, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        let scroll = app.scrollViews["remote-controls-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        let source = app.buttons["speaker-source-control"]
        for _ in 0..<12 {
            if source.isHittable { break }
            scroll.swipeUp()
        }
        XCTAssertTrue(source.isHittable, "Source control must be reachable by scrolling")
        source.tap()
        XCTAssertTrue(app.buttons["TV"].waitForExistence(timeout: 2))
        app.buttons["TV"].tap()
        let selectedTV = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Source, TV"), object: source
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selectedTV], timeout: 3), .completed)
        XCTAssertTrue(app.buttons["TV"].waitForNonExistence(timeout: 3))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Accessible landscape remote"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testSiriHelpExplainsReadyToUseCommands() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-mode", "--demo-show-settings"]
        app.launch()

        let helpLink = app.buttons["How to use Siri"]
        XCTAssertTrue(helpLink.waitForExistence(timeout: 3))
        helpLink.tap()

        XCTAssertTrue(app.navigationBars["Siri & Shortcuts"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Just ask Siri"].exists)
        XCTAssertEqual(
            app.staticTexts["siri-command-power"].label,
            "“Turn speakers on with Ampestra”"
        )
        XCTAssertEqual(
            app.staticTexts["siri-command-source-tv"].label,
            "“Set speakers to TV with Ampestra”"
        )

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Siri Shortcuts Help"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
