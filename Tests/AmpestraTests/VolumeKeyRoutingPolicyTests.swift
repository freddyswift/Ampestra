import XCTest
@testable import KEFCore

final class VolumeKeyRoutingPolicyTests: XCTestCase {
    func testMacModeNeverRoutesToSpeaker() {
        let policy = VolumeKeyRoutingPolicy(mode: .mac, speakerSources: Set(SpeakerSource.inputSources))

        XCTAssertFalse(
            policy.routesToSpeaker(
                isConnected: true,
                status: .powerOn,
                source: .wifi,
                isPlaying: true
            )
        )
        XCTAssertFalse(policy.requiresMediaKeyAccess)
    }

    func testSpeakerModeRoutesEverySource() {
        let policy = VolumeKeyRoutingPolicy(mode: .speaker, speakerSources: [])

        XCTAssertTrue(
            policy.routesToSpeaker(
                isConnected: true,
                status: .powerOn,
                source: .tv,
                isPlaying: false
            )
        )
        XCTAssertTrue(policy.requiresMediaKeyAccess)
    }

    func testAutomaticModeRoutesOnlySelectedSources() {
        let policy = VolumeKeyRoutingPolicy(mode: .auto, speakerSources: [.wifi])

        XCTAssertTrue(
            policy.routesToSpeaker(
                isConnected: true,
                status: .powerOn,
                source: .wifi,
                isPlaying: true
            )
        )
        XCTAssertFalse(
            policy.routesToSpeaker(
                isConnected: true,
                status: .powerOn,
                source: .tv,
                isPlaying: true
            )
        )
    }

    func testAutomaticNetworkSourcesReturnToMacWhilePaused() {
        let policy = VolumeKeyRoutingPolicy(mode: .auto, speakerSources: [.wifi, .bluetooth])

        XCTAssertFalse(
            policy.routesToSpeaker(
                isConnected: true,
                status: .powerOn,
                source: .wifi,
                isPlaying: false
            )
        )
        XCTAssertFalse(
            policy.routesToSpeaker(
                isConnected: true,
                status: .powerOn,
                source: .bluetooth,
                isPlaying: false
            )
        )
    }

    func testAutomaticPhysicalSourceRoutesWithoutPlaybackState() {
        let policy = VolumeKeyRoutingPolicy(mode: .auto, speakerSources: [.optical])

        XCTAssertTrue(
            policy.routesToSpeaker(
                isConnected: true,
                status: .powerOn,
                source: .optical,
                isPlaying: false
            )
        )
    }

    func testAutomaticModeWithNoSourcesNeedsNoPermissions() {
        let policy = VolumeKeyRoutingPolicy(mode: .auto, speakerSources: [])

        XCTAssertFalse(policy.requiresMediaKeyAccess)
        XCTAssertFalse(
            policy.routesToSpeaker(
                isConnected: true,
                status: .powerOn,
                source: .wifi,
                isPlaying: true
            )
        )
    }

    func testDisconnectedOrStandbySpeakerNeverConsumesMacKeys() {
        let policy = VolumeKeyRoutingPolicy(mode: .speaker, speakerSources: Set(SpeakerSource.inputSources))

        XCTAssertFalse(
            policy.routesToSpeaker(
                isConnected: false,
                status: .powerOn,
                source: .wifi,
                isPlaying: true
            )
        )
        XCTAssertFalse(
            policy.routesToSpeaker(
                isConnected: true,
                status: .standby,
                source: .wifi,
                isPlaying: true
            )
        )
    }
}
