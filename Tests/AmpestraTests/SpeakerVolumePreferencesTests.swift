import XCTest
@testable import KEFCore

final class SpeakerVolumePreferencesTests: XCTestCase {
    func testCeilingClampsCommandsAndAllowsSilence() {
        let preferences = SpeakerVolumePreferences(maximumVolume: 43)
        XCTAssertEqual(preferences.clampedVolume(80), 43)
        XCTAssertEqual(preferences.clampedVolume(20), 20)
        XCTAssertEqual(preferences.clampedVolume(-8), 0)
        XCTAssertEqual(SpeakerVolumePreferences(maximumVolume: 0).clampedVolume(20), 0)
        XCTAssertEqual(SpeakerVolumePreferences().clampedVolume(100), 100)
    }

    func testMalformedPersistedMaximumIsStillBounded() throws {
        let data = Data(#"{"maximumVolume":-50,"presets":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(SpeakerVolumePreferences.self, from: data)
        XCTAssertEqual(decoded.clampedVolume(50), 0)
    }

    func testCustomPresetsAndMaximumRoundTripWithoutChangingIdentity() throws {
        let preferences = SpeakerVolumePreferences(maximumVolume: 40, presets: [
            VolumePreset(name: "Evening", volume: 25),
        ])
        let decoded = try JSONDecoder().decode(SpeakerVolumePreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded, preferences)
        XCTAssertEqual(SpeakerVolumePreferences().presets, SpeakerVolumePreferences().presets)
    }
}
