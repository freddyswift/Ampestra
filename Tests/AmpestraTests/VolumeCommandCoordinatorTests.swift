import XCTest
@testable import Ampestra
@testable import KEFCore

@MainActor
final class VolumeCommandCoordinatorTests: XCTestCase {
    func testCoalescesRapidVolumeRequestsToLatestValue() async {
        let speaker = FakeSpeakerClient(host: "speaker.local")
        let coordinator = VolumeCommandCoordinator()
        let sentLatest = expectation(description: "sent latest volume")
        let timing = SpeakerTimingPolicy.immediate

        coordinator.submit(
            volume: 10,
            speaker: speaker,
            timing: timing,
            didSendLatest: { _ in sentLatest.fulfill() },
            didFailLatest: { _, _ in XCTFail("Unexpected failure") }
        )
        coordinator.submit(
            volume: 20,
            speaker: speaker,
            timing: timing,
            didSendLatest: { _ in sentLatest.fulfill() },
            didFailLatest: { _, _ in XCTFail("Unexpected failure") }
        )
        coordinator.submit(
            volume: 35,
            speaker: speaker,
            timing: timing,
            didSendLatest: { _ in sentLatest.fulfill() },
            didFailLatest: { _, _ in XCTFail("Unexpected failure") }
        )

        await fulfillment(of: [sentLatest], timeout: 1)
        XCTAssertEqual(speaker.setVolumes, [35])
    }

    func testCanceledWorkerDoesNotClearNewWorkerState() async {
        let speaker = FakeSpeakerClient(host: "speaker.local")
        let coordinator = VolumeCommandCoordinator()
        let sleeper = TestSleeper()
        let timing = SpeakerTimingPolicy.test { duration in
            try await sleeper.sleep(duration)
        }

        coordinator.submit(
            volume: 10,
            speaker: speaker,
            timing: timing,
            didSendLatest: { _ in XCTFail("Canceled worker should not finish") },
            didFailLatest: { _, _ in XCTFail("Canceled worker should not fail") }
        )

        await sleeper.waitForSleeps(count: 1)
        coordinator.cancel()

        let sentLatest = expectation(description: "new worker sent latest")
        coordinator.submit(
            volume: 20,
            speaker: speaker,
            timing: timing,
            didSendLatest: { _ in sentLatest.fulfill() },
            didFailLatest: { _, _ in XCTFail("Unexpected failure") }
        )

        await sleeper.waitForSleeps(count: 2)
        await sleeper.resumeAll()
        await sleeper.waitForSleeps(count: 3)
        await sleeper.resumeAll()

        await fulfillment(of: [sentLatest], timeout: 1)
        XCTAssertEqual(speaker.setVolumes, [20])

        coordinator.submit(
            volume: 25,
            speaker: speaker,
            timing: .immediate,
            didSendLatest: { _ in },
            didFailLatest: { _, _ in XCTFail("Unexpected failure") }
        )

        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(speaker.setVolumes, [20, 25])
    }
}

private extension SpeakerTimingPolicy {
    static let immediate = SpeakerTimingPolicy(
        autoDiscoveryTimeout: .seconds(0),
        autoDiscoveryPollInterval: .seconds(0),
        connectionRetryDelays: [.seconds(0)],
        stateRefreshPollInterval: .seconds(0),
        stateChangeTimeout: .seconds(0),
        playbackStateChangeTimeout: .seconds(0),
        pendingVolumeRetention: .seconds(0),
        volumeCommandCoalescingWindow: .seconds(0),
        postVolumeRefreshDelay: .seconds(0),
        sourceVolumeSettleDelay: .seconds(0),
        trackRefreshDelay: .seconds(0),
        wakePollInterval: .seconds(0),
        wakeAttemptCount: 0,
        sleep: { _ in }
    )

    static func test(sleep: @escaping @Sendable (Duration) async throws -> Void) -> SpeakerTimingPolicy {
        SpeakerTimingPolicy(
            autoDiscoveryTimeout: .seconds(0),
            autoDiscoveryPollInterval: .seconds(0),
            connectionRetryDelays: [.seconds(0)],
            stateRefreshPollInterval: .seconds(0),
            stateChangeTimeout: .seconds(0),
            playbackStateChangeTimeout: .seconds(0),
            pendingVolumeRetention: .seconds(0),
            volumeCommandCoalescingWindow: .milliseconds(1),
            postVolumeRefreshDelay: .milliseconds(1),
            sourceVolumeSettleDelay: .seconds(0),
            trackRefreshDelay: .seconds(0),
            wakePollInterval: .seconds(0),
            wakeAttemptCount: 0,
            sleep: sleep
        )
    }
}

private actor TestSleeper {
    private var sleepCount = 0
    private var sleepContinuations: [CheckedContinuation<Void, Error>] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func sleep(_ duration: Duration) async throws {
        sleepCount += 1
        resumeReadyWaiters()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepContinuations.append(continuation)
            }
        } onCancel: {
            Task { await self.resumeCanceledSleep() }
        }
    }

    func waitForSleeps(count: Int) async {
        if sleepCount >= count {
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    func resumeAll() {
        let continuations = sleepContinuations
        sleepContinuations = []
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func resumeCanceledSleep() {
        guard !sleepContinuations.isEmpty else { return }
        let continuation = sleepContinuations.removeFirst()
        continuation.resume(throwing: CancellationError())
    }

    private func resumeReadyWaiters() {
        let readyWaiters = waiters.filter { sleepCount >= $0.0 }
        waiters.removeAll { sleepCount >= $0.0 }
        for waiter in readyWaiters {
            waiter.1.resume()
        }
    }
}

private final class FakeSpeakerClient: KEFSpeakerClient, @unchecked Sendable {
    let host: String
    var setVolumes: [Int] = []

    init(host: String) {
        self.host = host
    }

    func getSnapshot() async throws -> SpeakerSnapshot {
        SpeakerSnapshot(status: .powerOn, source: .wifi, volume: setVolumes.last ?? 0, name: "Fake", model: "LSXII")
    }

    func getStatus() async throws -> SpeakerStatus { .powerOn }
    func getSource() async throws -> SpeakerSource { .wifi }
    func getVolume() async throws -> Int { setVolumes.last ?? 0 }
    func getSpeakerName() async throws -> String { "Fake" }
    func getModel() async throws -> String { "LSXII" }
    func getPlayerState() async throws -> PlayerState {
        PlayerState(isPlaying: true, nowPlaying: NowPlayingInfo(title: nil, artist: nil, album: nil))
    }
    func getIsPlaying() async throws -> Bool { true }
    func getNowPlayingInfo() async throws -> NowPlayingInfo {
        NowPlayingInfo(title: nil, artist: nil, album: nil)
    }
    func setVolume(_ volume: Int) async throws {
        setVolumes.append(volume)
    }
    func setSource(_ source: SpeakerSource) async throws {}
    func powerOn() async throws {}
    func shutdown() async throws {}
    func togglePlayPause() async throws {}
    func nextTrack() async throws {}
    func previousTrack() async throws {}
    func testConnection() async -> Bool { true }
}
