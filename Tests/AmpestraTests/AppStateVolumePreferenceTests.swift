import XCTest
@testable import Ampestra
@testable import KEFCore

@MainActor
final class AppStateVolumePreferenceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var originalStepPreferences: [String: Any] = [:]
    private let stepKeys = ["useFixedVolumeSteps", "volumeStepSize"]

    override func setUp() {
        super.setUp()
        suiteName = "AppStateVolumePreferenceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        for key in stepKeys {
            originalStepPreferences[key] = UserDefaults.standard.object(forKey: key)
        }
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        for key in stepKeys {
            if let value = originalStepPreferences[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        originalStepPreferences.removeAll()
        super.tearDown()
    }

    func testOrdinaryVolumeCommandsRespectCeilingAfterStepRounding() async throws {
        let (state, speaker) = makeState()
        defer { state.disconnect() }
        state.setUseFixedVolumeSteps(true)
        state.setVolumeStepSize(10)
        state.setSpeakerVolumePreferences(SpeakerVolumePreferences(maximumVolume: 43))

        state.commitVolume(89)

        XCTAssertEqual(state.displayedVolume, 43)
        try await waitForCommands([43], on: speaker)
    }

    func testLoweredCeilingReplacesQueuedHigherVolume() async throws {
        let (state, speaker) = makeState()
        defer { state.disconnect() }
        state.setUseFixedVolumeSteps(false)
        state.commitVolume(80)
        state.setSpeakerVolumePreferences(SpeakerVolumePreferences(maximumVolume: 27))

        XCTAssertEqual(state.displayedVolume, 27)
        try await waitForCommands([27], on: speaker)
    }

    func testMuteRestorationRespectsCeilingLoweredWhileMuted() async throws {
        let (state, speaker) = makeState()
        defer { state.disconnect() }
        state.setUseFixedVolumeSteps(false)
        state.commitVolume(70)
        try await waitForCommands([70], on: speaker)
        state.toggleSpeakerMute()
        try await waitForCommands([70, 0], on: speaker)
        state.setSpeakerVolumePreferences(SpeakerVolumePreferences(maximumVolume: 31))

        state.toggleSpeakerMute()

        XCTAssertEqual(state.displayedVolume, 31)
        try await waitForCommands([70, 0, 31], on: speaker)
    }

    func testPresetUsesExactLevelWithFixedStepsAndStillRespectsCeiling() async throws {
        let (state, speaker) = makeState()
        defer { state.disconnect() }
        state.setUseFixedVolumeSteps(true)
        state.setVolumeStepSize(10)
        let quiet = VolumePreset(name: "Quiet", volume: 23)
        let loud = VolumePreset(name: "Listening", volume: 68)
        state.setSpeakerVolumePreferences(SpeakerVolumePreferences(maximumVolume: 41, presets: [quiet, loud]))

        state.applyVolumePreset(quiet)
        XCTAssertEqual(state.displayedVolume, 23)
        try await waitForCommands([23], on: speaker)
        state.applyVolumePreset(loud)
        XCTAssertEqual(state.displayedVolume, 41)
        try await waitForCommands([23, 41], on: speaker)
    }

    func testSwitchingSpeakersKeepsLimitsAndPresetListsIndependent() {
        let (state, _) = makeState()
        defer { state.disconnect() }
        let kitchen = SpeakerVolumePreferences(maximumVolume: 37, presets: [VolumePreset(name: "Breakfast", volume: 17)])
        let office = SpeakerVolumePreferences(maximumVolume: 61, presets: [VolumePreset(name: "Focus", volume: 29)])
        state.setSpeakerVolumePreferences(kitchen)

        state.currentHost = "office.local"
        XCTAssertEqual(state.speakerVolumePreferences, SpeakerVolumePreferences())
        state.setSpeakerVolumePreferences(office)
        state.currentHost = "kitchen.local"
        XCTAssertEqual(state.speakerVolumePreferences, kitchen)
        state.currentHost = "office.local"
        XCTAssertEqual(state.speakerVolumePreferences, office)

        let restored = SpeakerVolumePreferenceStore(defaults: defaults)
        XCTAssertEqual(restored.preferences(host: "kitchen.local", macAddress: nil), kitchen)
        XCTAssertEqual(restored.preferences(host: "office.local", macAddress: nil), office)
    }

    func testSameMACRetainsPreferencesAfterHostChanges() {
        let (state, _) = makeState()
        defer { state.disconnect() }
        state.discovery.speakers = [
            DiscoveredSpeaker(id: "kitchen", name: "Kitchen", host: "kitchen.local", macAddress: "AA:BB:CC:DD:EE:FF")
        ]
        let preferences = SpeakerVolumePreferences(maximumVolume: 39, presets: [VolumePreset(name: "Evening", volume: 21)])
        state.setSpeakerVolumePreferences(preferences)

        state.currentHost = "192.168.1.88"
        state.discovery.speakers = [
            DiscoveredSpeaker(id: "kitchen", name: "Kitchen", host: "192.168.1.88", macAddress: "aa-bb-cc-dd-ee-ff")
        ]

        XCTAssertEqual(state.speakerVolumePreferences, preferences)
        XCTAssertEqual(SpeakerVolumePreferenceStore(defaults: defaults).preferences(
            host: "192.168.1.88", macAddress: "AABBCCDDEEFF"
        ), preferences)
        state.discovery.speakers = []
        XCTAssertEqual(state.speakerVolumePreferences, preferences)
    }

    func testDifferentKnownMACAtReusedHostDoesNotInheritPreferences() {
        let store = SpeakerVolumePreferenceStore(defaults: defaults)
        store.save(SpeakerVolumePreferences(maximumVolume: 85), host: "192.168.1.88", macAddress: "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(store.preferences(host: "192.168.1.88", macAddress: "11:22:33:44:55:66"), SpeakerVolumePreferences())
        store.save(SpeakerVolumePreferences(maximumVolume: 30), host: "192.168.1.88", macAddress: "11:22:33:44:55:66")
        XCTAssertEqual(store.preferences(host: "192.168.1.89", macAddress: "AA:BB:CC:DD:EE:FF").effectiveMaximumVolume, 85)
        XCTAssertEqual(store.preferences(host: "192.168.1.88", macAddress: nil).effectiveMaximumVolume, 30)
    }

    private func makeState() -> (AppState, PreferenceTestSpeaker) {
        let speaker = PreferenceTestSpeaker()
        var timing = SpeakerTimingPolicy.live
        timing.volumeCommandCoalescingWindow = .milliseconds(1)
        timing.postVolumeRefreshDelay = .milliseconds(1)
        timing.pendingVolumeRetention = .seconds(10)
        let state = AppState(
            timing: timing,
            volumePreferenceStore: SpeakerVolumePreferenceStore(defaults: defaults),
            startImmediately: false
        )
        // Inject the fake directly: discovery and live client creation never run.
        state.speaker = speaker
        state.currentHost = speaker.host
        state.isConnected = true
        state.status = .powerOn
        state.setVolumeHUDSuppressed(true)
        return (state, speaker)
    }

    private func waitForCommands(_ expected: [Int], on speaker: PreferenceTestSpeaker) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while await speaker.sentVolumes != expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let actual = await speaker.sentVolumes
        XCTAssertEqual(actual, expected)
    }
}

private actor PreferenceTestSpeaker: KEFSpeakerClient {
    nonisolated let host = "kitchen.local"
    private(set) var sentVolumes: [Int] = []
    private var volume = 0

    func getSnapshot() async throws -> SpeakerSnapshot {
        SpeakerSnapshot(status: .powerOn, source: .analog, volume: volume, name: "Kitchen", model: "LSXII")
    }
    func getStatus() async throws -> SpeakerStatus { .powerOn }
    func getSource() async throws -> SpeakerSource { .analog }
    func getVolume() async throws -> Int { volume }
    func getSpeakerName() async throws -> String { "Kitchen" }
    func getModel() async throws -> String { "LSXII" }
    func getPlayerState() async throws -> PlayerState { PlayerState(isPlaying: false, nowPlaying: NowPlayingInfo()) }
    func getIsPlaying() async throws -> Bool { false }
    func getNowPlayingInfo() async throws -> NowPlayingInfo { NowPlayingInfo() }
    func setVolume(_ volume: Int) async throws {
        sentVolumes.append(volume)
        self.volume = volume
    }
    func setSource(_ source: SpeakerSource) async throws {}
    func powerOn() async throws {}
    func shutdown() async throws {}
    func togglePlayPause() async throws {}
    func nextTrack() async throws {}
    func previousTrack() async throws {}
    func testConnection() async -> Bool { true }
}
