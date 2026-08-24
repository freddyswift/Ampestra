import Foundation
import Network
import XCTest
@testable import AmpestraMobile
@testable import KEFCore

@MainActor
final class MobileBehaviorTests: XCTestCase {
    func testOutputVolumeInterpreterInfersBothDirections() {
        var interpreter = OutputVolumeChangeInterpreter(initialVolume: 0.5)

        XCTAssertEqual(interpreter.direction(for: 0.5625), .up)
        XCTAssertEqual(interpreter.direction(for: 0.5), .down)
        XCTAssertNil(interpreter.direction(for: 0.5))
    }

    func testOutputVolumeLimitsRequestRecentering() {
        XCTAssertTrue(OutputVolumeChangeInterpreter.shouldRecenter(0))
        XCTAssertTrue(OutputVolumeChangeInterpreter.shouldRecenter(1))
        XCTAssertTrue(OutputVolumeChangeInterpreter.shouldRecenter(0.24))
        XCTAssertTrue(OutputVolumeChangeInterpreter.shouldRecenter(0.76))
        XCTAssertFalse(OutputVolumeChangeInterpreter.shouldRecenter(0.5))

        var atMinimum = OutputVolumeChangeInterpreter(initialVolume: 0)
        XCTAssertEqual(atMinimum.direction(for: 0.0625), .up)

        var atMaximum = OutputVolumeChangeInterpreter(initialVolume: 1)
        XCTAssertEqual(atMaximum.direction(for: 0.9375), .down)
    }

    func testRapidVolumeCommandsCoalesceToLatestValue() async {
        let speaker = StubSpeaker(snapshots: [])
        let dispatcher = VolumeCommandDispatcher(
            debounce: .zero,
            sleep: { _ in await Task.yield() }
        )
        let sent = expectation(description: "Latest volume sent")

        dispatcher.submit(20, to: speaker) { _ in sent.fulfill() }
        dispatcher.submit(25, to: speaker) { _ in sent.fulfill() }
        dispatcher.submit(30, to: speaker) { _ in sent.fulfill() }

        await fulfillment(of: [sent], timeout: 1)
        let recordedVolumes = await speaker.recordedVolumes()
        XCTAssertEqual(recordedVolumes, [30])
    }

    func testReconnectPolicyBacksOffAndCaps() {
        let policy = ReconnectPolicy(delays: [.seconds(1), .seconds(2), .seconds(5)])

        XCTAssertEqual(policy.delay(afterFailure: 1), .seconds(1))
        XCTAssertEqual(policy.delay(afterFailure: 2), .seconds(2))
        XCTAssertEqual(policy.delay(afterFailure: 3), .seconds(5))
        XCTAssertEqual(policy.delay(afterFailure: 20), .seconds(5))
    }

    func testStoreRecoversAfterSpeakerDisconnect() async throws {
        let poweredOn = SpeakerSnapshot(
            status: .powerOn,
            source: .wifi,
            volume: 44,
            name: "Office",
            model: "LSXII"
        )
        let speaker = StubSpeaker(snapshots: [
            .success(poweredOn),
            .failure(.unreachable),
            .success(poweredOn),
        ])
        let defaults = makeDefaults()
        let store = RemoteStore(
            defaults: defaults,
            reconnectPolicy: ReconnectPolicy(delays: [.seconds(60)]),
            pollingInterval: .milliseconds(100),
            clientFactory: { _ in speaker }
        )

        store.setAppActive(true)
        store.connect(to: "192.168.1.40")
        try await waitUntil { store.connectionState == .connected }
        try await waitUntil {
            if case .reconnecting = store.connectionState { return true }
            return false
        }

        store.refreshNow()
        try await waitUntil { store.connectionState == .connected }

        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.volume, 44)
        store.setAppActive(false)
    }

    func testStandbyIsConnectedButDisablesVolumeControls() async throws {
        let standby = SpeakerSnapshot(
            status: .standby,
            source: .wifi,
            volume: 18,
            name: "Bedroom",
            model: "LS50WII"
        )
        let speaker = StubSpeaker(snapshots: [.success(standby)])
        let store = RemoteStore(
            defaults: makeDefaults(),
            pollingInterval: .seconds(60),
            clientFactory: { _ in speaker }
        )

        store.setAppActive(true)
        store.connect(to: "192.168.1.41")
        try await waitUntil { store.connectionState == .connected }

        XCTAssertEqual(store.speakerStatus, .standby)
        XCTAssertFalse(store.canControlSpeaker)
        XCTAssertFalse(store.hardwareButtons.isCapturing)
        store.setAppActive(false)
    }

    func testStorePublishesNowPlayingMetadataForNetworkPlayback() async throws {
        let snapshot = SpeakerSnapshot(
            status: .powerOn,
            source: .wifi,
            volume: 36,
            name: "Living Room",
            model: "LS60"
        )
        let speaker = StubSpeaker(
            snapshots: [.success(snapshot)],
            playerState: PlayerState(
                isPlaying: true,
                nowPlaying: NowPlayingInfo(
                    title: "  Night Drive  ",
                    artist: "The Speakers",
                    album: "Living Room Sessions"
                )
            )
        )
        let store = RemoteStore(
            defaults: makeDefaults(),
            pollingInterval: .seconds(60),
            clientFactory: { _ in speaker }
        )

        store.setAppActive(true)
        store.connect(to: "192.168.1.42")
        try await waitUntil { store.nowPlaying?.title == "Night Drive" }

        XCTAssertTrue(store.isPlaying)
        XCTAssertEqual(store.nowPlaying?.artist, "The Speakers")
        XCTAssertEqual(store.nowPlaying?.album, "Living Room Sessions")
        store.setAppActive(false)
    }

    func testStoreClearsNowPlayingForSourcesWithoutMetadata() async throws {
        let wifi = SpeakerSnapshot(
            status: .powerOn,
            source: .wifi,
            volume: 36,
            name: "Living Room",
            model: "LS60"
        )
        let tv = SpeakerSnapshot(
            status: .powerOn,
            source: .tv,
            volume: 36,
            name: "Living Room",
            model: "LS60"
        )
        let speaker = StubSpeaker(
            snapshots: [.success(wifi), .success(tv)],
            playerState: PlayerState(
                isPlaying: true,
                nowPlaying: NowPlayingInfo(title: "Night Drive", artist: "The Speakers")
            )
        )
        let store = RemoteStore(
            defaults: makeDefaults(),
            pollingInterval: .seconds(60),
            clientFactory: { _ in speaker }
        )

        store.setAppActive(true)
        store.connect(to: "192.168.1.42")
        try await waitUntil { store.nowPlaying != nil }

        store.refreshNow()
        try await waitUntil { store.source == .tv }

        XCTAssertNil(store.nowPlaying)
        XCTAssertFalse(store.isPlaying)
        store.setAppActive(false)
    }

    func testStoreSendsPlaybackTransportCommands() async throws {
        let snapshot = SpeakerSnapshot(
            status: .powerOn,
            source: .wifi,
            volume: 36,
            name: "Living Room",
            model: "LS60"
        )
        let speaker = StubSpeaker(
            snapshots: [.success(snapshot)],
            playerState: PlayerState(
                isPlaying: true,
                nowPlaying: NowPlayingInfo(title: "Night Drive", artist: "The Speakers")
            )
        )
        let store = RemoteStore(
            defaults: makeDefaults(),
            pollingInterval: .seconds(60),
            clientFactory: { _ in speaker }
        )

        store.setAppActive(true)
        store.connect(to: "192.168.1.42")
        try await waitUntil { store.nowPlaying != nil }

        store.previousTrack()
        try await waitUntil { !store.isSendingCommand }
        store.togglePlayPause()
        try await waitUntil { !store.isSendingCommand }
        store.nextTrack()
        try await waitUntil { !store.isSendingCommand }

        let commands = await speaker.recordedPlaybackCommands()
        XCTAssertEqual(commands, ["previous", "playPause", "next"])
        store.setAppActive(false)
    }

    func testMutePhoneOnExitPreferencePersists() {
        let defaults = makeDefaults()
        let store = RemoteStore(defaults: defaults)

        XCTAssertFalse(store.mutePhoneOnExit)
        store.mutePhoneOnExit = true

        XCTAssertTrue(defaults.bool(forKey: SpeakerPreferenceKeys.mutePhoneOnExit))
    }

    func testPermissionDenialProducesActionableState() {
        let store = RemoteStore(defaults: makeDefaults())

        store.handleLocalNetworkPermissionDenied()

        XCTAssertTrue(store.localNetworkPermissionDenied)
        XCTAssertEqual(store.connectionState, .failed(message: "Local Network access is off"))
        XCTAssertTrue(store.lastError?.contains("Settings") == true)
    }

    func testSpeakerCommandServiceAdjustsVolumeByFive() async throws {
        let snapshot = SpeakerSnapshot(
            status: .powerOn,
            source: .wifi,
            volume: 42,
            name: "Living Room",
            model: "LS60"
        )
        let speaker = StubSpeaker(snapshots: [.success(snapshot)])
        let defaults = makeDefaults()
        defaults.set(speaker.host, forKey: SpeakerPreferenceKeys.savedHost)
        let service = SpeakerCommandService(defaults: defaults) { _ in speaker }

        let confirmation = try await service.adjustVolume(by: 5)

        XCTAssertEqual(confirmation.message, "Living Room volume is 47.")
        let volumes = await speaker.recordedVolumes()
        XCTAssertEqual(volumes, [47])
    }

    func testSpeakerCommandServiceChangesSource() async throws {
        let snapshot = SpeakerSnapshot(
            status: .powerOn,
            source: .wifi,
            volume: 35,
            name: "Office",
            model: "LSXII"
        )
        let speaker = StubSpeaker(snapshots: [.success(snapshot)])
        let defaults = makeDefaults()
        defaults.set(speaker.host, forKey: SpeakerPreferenceKeys.savedHost)
        let service = SpeakerCommandService(defaults: defaults) { _ in speaker }

        let confirmation = try await service.setSource(.tv)

        XCTAssertEqual(confirmation.message, "Office is set to TV.")
        let sources = await speaker.recordedSources()
        XCTAssertEqual(sources, [.tv])
    }

    func testSpeakerCommandServiceRequiresConfiguredSpeaker() async {
        let service = SpeakerCommandService(defaults: makeDefaults())

        do {
            _ = try await service.setVolume(30)
            XCTFail("Expected a missing-speaker error")
        } catch {
            XCTAssertEqual(error as? SpeakerCommandError, .noConfiguredSpeaker)
        }
    }

    func testSpeakerCommandServicePowerIsIdempotent() async throws {
        let snapshot = SpeakerSnapshot(
            status: .standby,
            source: .wifi,
            volume: 20,
            name: "Bedroom",
            model: "LS50WII"
        )
        let speaker = StubSpeaker(snapshots: [.success(snapshot)])
        let defaults = makeDefaults()
        defaults.set(speaker.host, forKey: SpeakerPreferenceKeys.savedHost)
        let service = SpeakerCommandService(defaults: defaults) { _ in speaker }

        let confirmation = try await service.setPower(on: true)

        XCTAssertEqual(confirmation.message, "Bedroom is on.")
        let powerCommands = await speaker.recordedPowerCommands()
        XCTAssertEqual(powerCommands, [true])
    }

    func testBonjourPolicyDenialIsRecognized() {
        XCTAssertTrue(
            KEFDiscovery.isLocalNetworkPolicyDenied(
                .dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))
            )
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "MobileBehaviorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition was not met before timeout")
    }
}

private actor StubSpeaker: KEFSpeakerClient {
    enum StubFailure: Error {
        case unreachable
    }

    enum SnapshotResult {
        case success(SpeakerSnapshot)
        case failure(StubFailure)
    }

    nonisolated let host = "192.168.1.99"
    private var snapshots: [SnapshotResult]
    private let playerState: PlayerState
    private var volumes: [Int] = []
    private var sources: [SpeakerSource] = []
    private var powerCommands: [Bool] = []
    private var playbackCommands: [String] = []

    init(
        snapshots: [SnapshotResult],
        playerState: PlayerState = PlayerState(isPlaying: false, nowPlaying: NowPlayingInfo())
    ) {
        self.snapshots = snapshots
        self.playerState = playerState
    }

    func getSnapshot() async throws -> SpeakerSnapshot {
        guard !snapshots.isEmpty else {
            return SpeakerSnapshot(status: .powerOn, source: .wifi, volume: 30, name: "Test", model: "LS60")
        }

        switch snapshots.removeFirst() {
        case .success(let snapshot):
            return snapshot
        case .failure(let error):
            throw error
        }
    }

    func getStatus() async throws -> SpeakerStatus { try await getSnapshot().status }
    func getSource() async throws -> SpeakerSource { try await getSnapshot().source }
    func getVolume() async throws -> Int { try await getSnapshot().volume }
    func getSpeakerName() async throws -> String { try await getSnapshot().name }
    func getModel() async throws -> String { try await getSnapshot().model }
    func getPlayerState() async throws -> PlayerState { playerState }
    func getIsPlaying() async throws -> Bool { playerState.isPlaying }
    func getNowPlayingInfo() async throws -> NowPlayingInfo { playerState.nowPlaying }

    func setVolume(_ volume: Int) async throws {
        volumes.append(volume)
    }

    func setSource(_ source: SpeakerSource) async throws {
        sources.append(source)
    }

    func powerOn() async throws {
        powerCommands.append(true)
    }

    func shutdown() async throws {
        powerCommands.append(false)
    }
    func togglePlayPause() async throws {
        playbackCommands.append("playPause")
    }

    func nextTrack() async throws {
        playbackCommands.append("next")
    }

    func previousTrack() async throws {
        playbackCommands.append("previous")
    }
    func validateConnection() async throws {}
    func testConnection() async -> Bool { true }

    func recordedVolumes() -> [Int] { volumes }
    func recordedSources() -> [SpeakerSource] { sources }
    func recordedPowerCommands() -> [Bool] { powerCommands }
    func recordedPlaybackCommands() -> [String] { playbackCommands }
}
