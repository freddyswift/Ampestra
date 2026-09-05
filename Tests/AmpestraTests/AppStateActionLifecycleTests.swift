import XCTest
@testable import Ampestra
@testable import KEFCore

@MainActor
final class AppStateActionLifecycleTests: XCTestCase {
    func testBusyMediaKeysFallThroughInsteadOfBeingSwallowed() {
        let defaults = UserDefaults.standard
        let previousRouting = defaults.object(forKey: "volumeKeyRoutingMode")
        let (state, _) = makeState()
        defer {
            state.volumeKeyRoutingMode = .mac
            if let previousRouting {
                defaults.set(previousRouting, forKey: "volumeKeyRoutingMode")
            } else {
                defaults.removeObject(forKey: "volumeKeyRoutingMode")
            }
            state.disconnect()
        }
        state.volumeKeyRoutingMode = .speaker
        XCTAssertTrue(state.handleVolumeKey(0))
        XCTAssertTrue(state.handleMuteKey())

        state.isBusy = true

        XCTAssertFalse(state.handleVolumeKey(1))
        XCTAssertFalse(state.handleMuteKey())
    }

    func testCancelledRefreshDoesNotRecordConnectionFailure() async {
        let (state, speaker) = makeState()
        defer { state.disconnect() }
        state.connectionSession.consecutiveRefreshFailures = 2
        await speaker.suspendSnapshotRequest()
        let refresh = Task { await state.refresh() }
        await waitUntil { await speaker.isSnapshotSuspended }

        refresh.cancel()
        await speaker.failSuspendedSnapshot()
        await refresh.value

        XCTAssertTrue(state.isConnected)
        XCTAssertFalse(state.isReconnecting)
        XCTAssertEqual(state.connectionSession.consecutiveRefreshFailures, 2)
        let probes = await speaker.connectionProbeCount
        XCTAssertEqual(probes, 0)
    }

    func testChangingSourceCancelsQueuedVolumeForPreviousInput() async throws {
        let (state, speaker) = makeState()
        defer { state.disconnect() }

        state.commitVolume(60)
        state.setSource(.analog)
        await waitUntil { !state.isBusy }
        try await Task.sleep(for: .milliseconds(100))

        let writes = await speaker.sentVolumes
        XCTAssertEqual(writes, [])
        XCTAssertEqual(state.source, .analog)
        XCTAssertEqual(state.displayedVolume, 35)
    }

    func testPoweringOffCancelsQueuedVolume() async throws {
        let (state, speaker) = makeState()
        defer { state.disconnect() }

        state.commitVolume(60)
        state.togglePower()
        await waitUntil { !state.isBusy }
        try await Task.sleep(for: .milliseconds(100))

        let writes = await speaker.sentVolumes
        XCTAssertEqual(writes, [])
        XCTAssertEqual(state.status, .standby)
    }

    func testVolumeAndMuteAreIgnoredDuringTransitionOrDisconnection() async throws {
        let (state, speaker) = makeState()
        defer { state.disconnect() }
        state.volume = 35
        state.syncDisplayedVolume(with: 35)
        state.isBusy = true

        state.commitVolume(60)
        state.toggleSpeakerMute()
        XCTAssertEqual(state.displayedVolume, 35)

        state.isBusy = false
        state.isConnected = false
        state.commitVolume(60)
        state.toggleSpeakerMute()
        XCTAssertEqual(state.displayedVolume, 35)
        try await Task.sleep(for: .milliseconds(100))
        let writes = await speaker.sentVolumes
        XCTAssertEqual(writes, [])
    }

    func testChangingInputDoesNotRestoreMuteVolumeFromPreviousInput() async {
        let (state, speaker) = makeState()
        defer { state.disconnect() }
        state.volume = 35
        state.syncDisplayedVolume(with: 35)
        state.toggleSpeakerMute()
        await waitUntil { await speaker.sentVolumes == [0] }

        try? await speaker.setSource(.analog)
        await state.refresh()
        state.toggleSpeakerMute()

        XCTAssertEqual(state.displayedVolume, 0)
        let writes = await speaker.sentVolumes
        XCTAssertEqual(writes, [0])
    }

    func testOlderPlaybackResponseCannotReplaceNewerInputMetadata() async {
        let (state, speaker) = makeState()
        defer { state.disconnect() }
        await speaker.suspendPlayerRequests()
        let oldRequest = Task { await state.refreshPlayerState(for: speaker, clearOnFailure: true) }
        await waitUntil { await speaker.playerRequestCount == 1 }

        state.source = .bluetooth
        let newRequest = Task { await state.refreshPlayerState(for: speaker, clearOnFailure: true) }
        await waitUntil { await speaker.playerRequestCount == 2 }
        await speaker.resumePlayerRequest(1, title: "Bluetooth track", isPlaying: false)
        await newRequest.value
        await speaker.resumePlayerRequest(0, title: "Old Wi-Fi track", isPlaying: true)
        await oldRequest.value

        XCTAssertEqual(state.nowPlaying?.title, "Bluetooth track")
        XCTAssertFalse(state.isPlaying)
    }

    func testLatePlaybackResponseIsIgnoredAfterSourceChangesWithoutAnotherPoll() async {
        let (state, speaker) = makeState()
        defer { state.disconnect() }
        await speaker.suspendPlayerRequests()
        let request = Task { await state.refreshPlayerState(for: speaker, clearOnFailure: true) }
        await waitUntil { await speaker.playerRequestCount == 1 }

        state.source = .analog
        await speaker.resumePlayerRequest(0, title: "Old Wi-Fi track", isPlaying: true)
        await request.value

        XCTAssertNil(state.nowPlaying)
        XCTAssertFalse(state.isPlaying)
        XCTAssertNil(state.connectionSession.lastPlaybackStateRefresh)
    }

    private func makeState() -> (AppState, LifecycleTestSpeaker) {
        let speaker = LifecycleTestSpeaker()
        var timing = SpeakerTimingPolicy.live
        timing.volumeCommandCoalescingWindow = .milliseconds(50)
        timing.stateRefreshPollInterval = .milliseconds(1)
        timing.sourceVolumeSettleDelay = .milliseconds(1)
        let state = AppState(timing: timing, startImmediately: false)
        state.speaker = speaker
        state.currentHost = speaker.host
        state.isConnected = true
        state.status = .powerOn
        state.setVolumeHUDSuppressed(true)
        return (state, speaker)
    }

    private func waitUntil(
        condition: @escaping @MainActor () async -> Bool
    ) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while !(await condition()), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        let satisfied = await condition()
        XCTAssertTrue(satisfied, "Condition was not met before timeout")
    }
}

private actor LifecycleTestSpeaker: KEFSpeakerClient {
    nonisolated let host = "lifecycle-test.local"
    private var source: SpeakerSource = .wifi
    private var status: SpeakerStatus = .powerOn
    private var volume = 35
    private var shouldSuspendSnapshot = false
    private var snapshotRequest: CheckedContinuation<Void, Error>?
    private(set) var connectionProbeCount = 0
    private(set) var sentVolumes: [Int] = []
    private var shouldSuspendPlayerRequests = false
    private var playerRequests: [Int: CheckedContinuation<PlayerState, Never>] = [:]
    private(set) var playerRequestCount = 0

    func suspendPlayerRequests() { shouldSuspendPlayerRequests = true }

    var isSnapshotSuspended: Bool { snapshotRequest != nil }
    func suspendSnapshotRequest() { shouldSuspendSnapshot = true }
    func failSuspendedSnapshot() {
        snapshotRequest?.resume(throwing: URLError(.cancelled))
        snapshotRequest = nil
    }

    func resumePlayerRequest(_ index: Int, title: String, isPlaying: Bool) {
        playerRequests.removeValue(forKey: index)?.resume(returning: PlayerState(
            isPlaying: isPlaying, nowPlaying: NowPlayingInfo(title: title)
        ))
    }

    func getSnapshot() async throws -> SpeakerSnapshot {
        if shouldSuspendSnapshot {
            try await withCheckedThrowingContinuation { snapshotRequest = $0 }
        }
        return SpeakerSnapshot(status: status, source: source, volume: volume, name: "Test", model: "LSXII")
    }
    func getStatus() async throws -> SpeakerStatus { status }
    func getSource() async throws -> SpeakerSource { source }
    func getVolume() async throws -> Int { volume }
    func getSpeakerName() async throws -> String { "Test" }
    func getModel() async throws -> String { "LSXII" }
    func getPlayerState() async throws -> PlayerState {
        guard shouldSuspendPlayerRequests else {
            return PlayerState(isPlaying: false, nowPlaying: NowPlayingInfo())
        }
        let index = playerRequestCount
        playerRequestCount += 1
        return await withCheckedContinuation { playerRequests[index] = $0 }
    }
    func getIsPlaying() async throws -> Bool { false }
    func getNowPlayingInfo() async throws -> NowPlayingInfo { NowPlayingInfo() }
    func setVolume(_ volume: Int) async throws {
        sentVolumes.append(volume)
        self.volume = volume
    }
    func setSource(_ source: SpeakerSource) async throws { self.source = source }
    func powerOn() async throws { status = .powerOn }
    func shutdown() async throws { status = .standby }
    func togglePlayPause() async throws {}
    func nextTrack() async throws {}
    func previousTrack() async throws {}
    func testConnection() async -> Bool {
        connectionProbeCount += 1
        return !shouldSuspendSnapshot
    }
}
