import AppIntentsTesting
import XCTest

final class WidgetIntentMetadataTests: XCTestCase {
    private let bundleIdentifier = "com.freddyswift.ampestra"

    func testWidgetConfigurationExportsItsSpeakerEntityParameter() throws {
        let definitions = IntentDefinitions(bundleIdentifier: bundleIdentifier)
        let entityDefinition = definitions.entities["WidgetSpeakerEntity"]
        XCTAssertEqual(entityDefinition.bundleIdentifier, bundleIdentifier)
        XCTAssertEqual(entityDefinition.typeIdentifier, "WidgetSpeakerEntity")

        let selected = entityDefinition.makeReference(identifier: "saved-speaker-widget-target")
        let configuration = definitions.intents["SelectWidgetSpeakerIntent"].makeIntent(speaker: selected)
        let exportedSpeaker: AnyAppEntity = try configuration.speaker
        XCTAssertEqual(exportedSpeaker, selected)
    }

    func testExistingWidgetActionsExportStableSpeakerIDParameters() throws {
        let definitions = IntentDefinitions(bundleIdentifier: bundleIdentifier)
        let speakerID = "saved-speaker-widget-target"
        for identifier in [
            "LowerSpeakerVolumeWidgetIntent",
            "RaiseSpeakerVolumeWidgetIntent",
            "MuteSpeakerWidgetIntent",
        ] {
            let intent = definitions.intents[identifier].makeIntent(speakerID: speakerID)
            let exportedID: String = try intent.speakerID
            XCTAssertEqual(exportedID, speakerID, "\(identifier) must keep the displayed speaker's identity")
        }
    }
}
