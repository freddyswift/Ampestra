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

        XCTAssertEqual(String(localized: confirmation.message), "Living Room volume is 47.")
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

        XCTAssertEqual(String(localized: confirmation.message), "Office is set to TV.")
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

    func testSpeakerCommandServicePowersOnSpeakerInStandby() async throws {
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

        XCTAssertEqual(String(localized: confirmation.message), "Bedroom is on.")
        let powerCommands = await speaker.recordedPowerCommands()
        XCTAssertEqual(powerCommands, [true])
    }

    func testSavedSpeakerMigrationCreatesStableIdentity() {
        let defaults = makeDefaults()
        defaults.set("192.168.1.60", forKey: SpeakerPreferenceKeys.savedHost)
        defaults.set("aabbccddeeff", forKey: SpeakerPreferenceKeys.savedMACAddress)

        let firstStore = SpeakerRecordStore(defaults: defaults)
        let firstRecord = firstStore.defaultSpeaker()
        let reloadedRecord = SpeakerRecordStore(defaults: defaults).defaultSpeaker()

        XCTAssertNotNil(defaults.data(forKey: SpeakerPreferenceKeys.savedSpeakers))
        XCTAssertEqual(firstRecord?.id, reloadedRecord?.id)
        XCTAssertEqual(firstRecord?.host, "192.168.1.60")
        XCTAssertEqual(firstRecord?.macAddress, "AA:BB:CC:DD:EE:FF")
        XCTAssertNil(defaults.object(forKey: SpeakerPreferenceKeys.savedHost))
        XCTAssertNil(defaults.object(forKey: SpeakerPreferenceKeys.savedMACAddress))
    }

    func testSavedSpeakerKeepsIdentityWhenAddressChanges() throws {
        let records = SpeakerRecordStore(defaults: makeDefaults())
        let first = try XCTUnwrap(
            records.save(
                host: "192.168.1.60",
                macAddress: "AA:BB:CC:DD:EE:FF",
                snapshot: speakerSnapshot(name: "Living Room")
            )
        )
        let moved = try XCTUnwrap(
            records.save(
                host: "living-room.local",
                macAddress: "aa-bb-cc-dd-ee-ff",
                snapshot: speakerSnapshot(name: "Living Room")
            )
        )

        XCTAssertEqual(moved.id, first.id)
        XCTAssertEqual(moved.host, "living-room.local")
        XCTAssertEqual(moved.alternateHosts, ["192.168.1.60"])
        XCTAssertEqual(records.allSpeakers().count, 1)
    }

    func testSavingNonDefaultSpeakerDoesNotChangeDefault() throws {
        let records = SpeakerRecordStore(defaults: makeDefaults())
        let defaultRecord = try XCTUnwrap(
            records.save(
                host: "192.168.1.60",
                macAddress: "AA:BB:CC:DD:EE:FF",
                snapshot: speakerSnapshot(name: "Living Room")
            )
        )
        _ = records.save(
            host: "192.168.1.61",
            macAddress: "11:22:33:44:55:66",
            snapshot: speakerSnapshot(name: "Office"),
            makeDefault: false
        )

        XCTAssertEqual(records.defaultSpeaker()?.id, defaultRecord.id)
    }

    func testSpeakerEntityUsesSavedStableIdentity() throws {
        let records = SpeakerRecordStore(defaults: makeDefaults())
        let record = try XCTUnwrap(
            records.save(
                host: "192.168.1.60",
                macAddress: nil,
                snapshot: speakerSnapshot(name: "Kitchen", model: "LSXII")
            )
        )

        let entity = SpeakerEntity(record: record)

        XCTAssertEqual(entity.id, record.id)
        XCTAssertEqual(entity.name, "Kitchen")
        XCTAssertEqual(entity.model, "LSXII")
    }

    func testSpeakerCommandServiceUsesConfiguredVolumeStep() async throws {
        let defaults = makeDefaults()
        defaults.set(7, forKey: SpeakerPreferenceKeys.volumeStep)
        let records = SpeakerRecordStore(defaults: defaults)
        let snapshot = speakerSnapshot(volume: 42)
        _ = records.save(host: "192.168.1.60", macAddress: nil, snapshot: snapshot)
        let speaker = StubSpeaker(snapshots: [.success(snapshot)])
        let service = SpeakerCommandService(speakerRecords: records) { _ in speaker }

        let confirmation = try await service.adjustVolume(direction: 1)
        let volumes = await speaker.recordedVolumes()

        XCTAssertEqual(confirmation.volume, 49)
        XCTAssertEqual(volumes, [49])
    }

    func testSpeakerCommandServiceRestoresLastAudibleVolume() async throws {
        let records = SpeakerRecordStore(defaults: makeDefaults())
        _ = records.save(
            host: "192.168.1.60",
            macAddress: nil,
            snapshot: speakerSnapshot(volume: 38)
        )
        let mutedSnapshot = speakerSnapshot(volume: 0)
        let speaker = StubSpeaker(snapshots: [.success(mutedSnapshot)])
        let service = SpeakerCommandService(speakerRecords: records) { _ in speaker }

        let confirmation = try await service.setMuted(false)
        let volumes = await speaker.recordedVolumes()

        XCTAssertEqual(confirmation.volume, 38)
        XCTAssertEqual(volumes, [38])
    }

    func testSpeakerCommandServiceRetriesTransientRead() async throws {
        let records = SpeakerRecordStore(defaults: makeDefaults())
        let snapshot = speakerSnapshot()
        _ = records.save(host: "192.168.1.60", macAddress: nil, snapshot: snapshot)
        let speaker = StubSpeaker(snapshots: [.failure(.unreachable), .success(snapshot)])
        let timing = SpeakerCommandTimingPolicy(
            readAttempts: 2,
            readRetryDelay: .zero,
            wakePollingDelays: []
        )
        let service = SpeakerCommandService(
            speakerRecords: records,
            clientFactory: { _ in speaker },
            timing: timing,
            sleep: { _ in }
        )

        let confirmation = try await service.status()
        let readCount = await speaker.snapshotReadCount()

        XCTAssertEqual(confirmation.speakerName, "Living Room")
        XCTAssertEqual(readCount, 2)
    }

    func testSpeakerCommandServiceFallsBackToPreviousAddress() async throws {
        let records = SpeakerRecordStore(defaults: makeDefaults())
        let snapshot = speakerSnapshot()
        let first = try XCTUnwrap(
            records.save(
                host: "192.168.1.60",
                macAddress: "AA:BB:CC:DD:EE:FF",
                snapshot: snapshot
            )
        )
        _ = records.save(
            host: "living-room.local",
            macAddress: "AA:BB:CC:DD:EE:FF",
            snapshot: snapshot
        )
        let unavailable = StubSpeaker(snapshots: [.failure(.unreachable)])
        let reachable = StubSpeaker(snapshots: [.success(snapshot)])
        let timing = SpeakerCommandTimingPolicy(
            readAttempts: 1,
            readRetryDelay: .zero,
            wakePollingDelays: []
        )
        let service = SpeakerCommandService(
            speakerRecords: records,
            clientFactory: { host in
                host == "living-room.local" ? unavailable : reachable
            },
            timing: timing,
            sleep: { _ in }
        )

        let confirmation = try await service.status(speakerID: first.id)
        let unavailableReads = await unavailable.snapshotReadCount()
        let reachableReads = await reachable.snapshotReadCount()

        XCTAssertEqual(confirmation.speakerID, first.id)
        XCTAssertEqual(records.speaker(id: first.id)?.host, "192.168.1.60")
        XCTAssertEqual(unavailableReads, 1)
        XCTAssertEqual(reachableReads, 1)
    }

    func testSpeakerCommandServiceUsesWakeOnLANWhenSpeakerIsOffline() async throws {
        let records = SpeakerRecordStore(defaults: makeDefaults())
        let snapshot = speakerSnapshot(status: .standby)
        _ = records.save(
            host: "192.168.1.60",
            macAddress: "AA:BB:CC:DD:EE:FF",
            snapshot: snapshot
        )
        let speaker = StubSpeaker(snapshots: [.failure(.unreachable), .success(snapshot)])
        let wakeRecorder = WakeRecorder()
        let timing = SpeakerCommandTimingPolicy(
            readAttempts: 1,
            readRetryDelay: .zero,
            wakePollingDelays: [.zero]
        )
        let service = SpeakerCommandService(
            speakerRecords: records,
            clientFactory: { _ in speaker },
            timing: timing,
            sleep: { _ in },
            wakeSender: { macAddress in
                wakeRecorder.record(macAddress)
                return true
            }
        )

        let confirmation = try await service.setPower(on: true)
        let powerCommands = await speaker.recordedPowerCommands()

        XCTAssertEqual(wakeRecorder.addresses, ["AA:BB:CC:DD:EE:FF"])
        XCTAssertEqual(powerCommands, [true])
        XCTAssertTrue(confirmation.changed)
        XCTAssertEqual(confirmation.status, .powerOn)
    }

    func testSpeakerCommandServiceDoesNotRepeatSatisfiedPowerCommand() async throws {
        let records = SpeakerRecordStore(defaults: makeDefaults())
        let snapshot = speakerSnapshot(status: .powerOn)
        _ = records.save(host: "192.168.1.60", macAddress: nil, snapshot: snapshot)
        let speaker = StubSpeaker(snapshots: [.success(snapshot)])
        let service = SpeakerCommandService(speakerRecords: records) { _ in speaker }

        let confirmation = try await service.setPower(on: true)
        let powerCommands = await speaker.recordedPowerCommands()

        XCTAssertFalse(confirmation.changed)
        XCTAssertEqual(powerCommands, [])
    }

    func testSpeakerCommandServiceReportsMissingWakeAddress() async throws {
        let records = SpeakerRecordStore(defaults: makeDefaults())
        let snapshot = speakerSnapshot(status: .standby)
        _ = records.save(host: "192.168.1.60", macAddress: nil, snapshot: snapshot)
        let speaker = StubSpeaker(snapshots: [.failure(.unreachable)])
        let timing = SpeakerCommandTimingPolicy(
            readAttempts: 1,
            readRetryDelay: .zero,
            wakePollingDelays: [.zero]
        )
        let service = SpeakerCommandService(
            speakerRecords: records,
            clientFactory: { _ in speaker },
            timing: timing,
            sleep: { _ in }
        )

        do {
            _ = try await service.setPower(on: true)
            XCTFail("Expected a missing hardware-address error")
        } catch {
            XCTAssertEqual(error as? SpeakerCommandError, .wakeUnavailable)
        }
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

    private func speakerSnapshot(
        status: SpeakerStatus = .powerOn,
        source: SpeakerSource = .wifi,
        volume: Int = 35,
        name: String = "Living Room",
        model: String = "LS60"
    ) -> SpeakerSnapshot {
        SpeakerSnapshot(
            status: status,
            source: source,
            volume: volume,
            name: name,
            model: model
        )
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

    nonisolated let host: String
    private var snapshots: [SnapshotResult]
    private var snapshotReads = 0
    private let playerState: PlayerState
    private var volumes: [Int] = []
    private var sources: [SpeakerSource] = []
    private var powerCommands: [Bool] = []
    private var playbackCommands: [String] = []

    init(
        host: String = "192.168.1.99",
        snapshots: [SnapshotResult],
        playerState: PlayerState = PlayerState(isPlaying: false, nowPlaying: NowPlayingInfo())
    ) {
        self.host = host
        self.snapshots = snapshots
        self.playerState = playerState
    }

    func getSnapshot() async throws -> SpeakerSnapshot {
        snapshotReads += 1
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
    func snapshotReadCount() -> Int { snapshotReads }
}

private final class WakeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedAddresses: [String] = []

    var addresses: [String] {
        lock.withLock { recordedAddresses }
    }

    func record(_ address: String) {
        lock.withLock {
            recordedAddresses.append(address)
        }
    }
}
