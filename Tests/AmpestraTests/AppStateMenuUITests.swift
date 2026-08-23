import Combine
import XCTest
@testable import Ampestra
@testable import KEFCore

@MainActor
final class AppStateMenuUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        resetDefaults()
    }

    override func tearDown() {
        resetDefaults()
        super.tearDown()
    }

    func testFreshSetupDefersConnectionAndDefaultsToMacVolumeKeys() {
        let appState = AppState(startImmediately: false)

        XCTAssertFalse(appState.hasStartedConnection)
        XCTAssertEqual(appState.volumeKeyRoutingMode, .mac)
        XCTAssertFalse(appState.volumeKeyRoutingMode.requiresMediaKeyAccess)
        XCTAssertTrue(appState.shouldShowOnboarding)
    }

    func testOptionalKeyboardPermissionsDoNotBlockCompletedSpeakerSetup() {
        let appState = AppState(startImmediately: false)
        appState.volumeKeyRoutingMode = .auto

        appState.isConnected = true

        XCTAssertFalse(appState.shouldShowOnboarding)
    }

    func testVolumeKeySourcesCanBeConfiguredAndPersistIndependently() {
        let appState = AppState(startImmediately: false)

        XCTAssertEqual(appState.volumeKeyRoutingSources, Set(SpeakerSource.inputSources))

        appState.setVolumeKeyRoutingEnabled(false, for: .tv)

        XCTAssertTrue(appState.routesVolumeKeysToSpeaker(on: .wifi))
        XCTAssertFalse(appState.routesVolumeKeysToSpeaker(on: .tv))

        let restoredAppState = AppState(startImmediately: false)
        XCTAssertTrue(restoredAppState.routesVolumeKeysToSpeaker(on: .wifi))
        XCTAssertFalse(restoredAppState.routesVolumeKeysToSpeaker(on: .tv))
    }

    func testReturningUserCanConnectBeforeOpeningMenuPanel() async {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        let speaker = MenuUITestSpeaker()
        UserDefaults.standard.set(speaker.host, forKey: "manualIP")
        let appState = AppState(
            speakerClientFactory: MenuUITestSpeakerFactory(speaker: speaker),
            timing: .menuUITest,
            startImmediately: false
        )

        XCTAssertFalse(appState.hasStartedConnection)
        appState.startConnectionForReturningUserIfNeeded()

        await waitUntil { appState.isConnected }
        XCTAssertTrue(appState.hasStartedConnection)
    }

    func testDiscoveryChangesNotifyAppStateObservers() {
        let appState = AppState(startImmediately: false)
        var notificationCount = 0
        let observation = appState.objectWillChange.sink {
            notificationCount += 1
        }

        appState.discovery.speakers = [
            DiscoveredSpeaker(
                id: "speaker.local",
                name: "Living Room",
                host: "speaker.local",
                macAddress: nil
            )
        ]

        XCTAssertGreaterThan(notificationCount, 0)
        withExtendedLifetime(observation) {}
    }

    func testPausedTrackMetadataRemainsAvailableAfterRefresh() async {
        let speaker = MenuUITestSpeaker()
        speaker.playerState = PlayerState(
            isPlaying: false,
            nowPlaying: NowPlayingInfo(title: "Paused Track", artist: "Artist", album: "Album")
        )
        let appState = makeConnectedAppState(speaker: speaker)

        await waitUntil { appState.nowPlaying?.title == "Paused Track" }

        XCTAssertFalse(appState.isPlaying)
        XCTAssertEqual(appState.nowPlaying?.title, "Paused Track")
        XCTAssertEqual(appState.nowPlaying?.artist, "Artist")
    }

    func testTrackActionsExposeBusyStateAndFailureMessage() async {
        let speaker = MenuUITestSpeaker()
        speaker.nextTrackError = KEFError.apiError("Next track is unavailable")
        let appState = makeConnectedAppState(speaker: speaker)
        await waitUntil { appState.isConnected }

        appState.nextTrack()

        XCTAssertTrue(appState.isBusy)
        await waitUntil { !appState.isBusy }
        XCTAssertEqual(appState.actionError, "Next track is unavailable")
        XCTAssertNil(appState.connectionError)
        XCTAssertTrue(appState.isConnected)
    }

    func testSteadyStateRefreshDoesNotPublishUnchangedValues() async {
        let speaker = MenuUITestSpeaker()
        let appState = makeConnectedAppState(speaker: speaker)
        await waitUntil { appState.nowPlaying?.title == "Track" }

        var notificationCount = 0
        let observation = appState.objectWillChange.sink {
            notificationCount += 1
        }

        await appState.refresh()

        XCTAssertEqual(notificationCount, 0)
        withExtendedLifetime(observation) {}
    }

    func testLocalNetworkDenialProducesActionableConnectionError() async {
        let speaker = MenuUITestSpeaker()
        speaker.connectionValidationError = URLError(.notConnectedToInternet)
        let appState = makeConnectedAppState(speaker: speaker)

        await waitUntil { appState.needsLocalNetworkAccess }

        XCTAssertFalse(appState.isConnected)
        XCTAssertEqual(
            appState.connectionError,
            "macOS reports that Local Network access is blocked, even though System Settings may show it as enabled."
        )
    }

    private func makeConnectedAppState(speaker: MenuUITestSpeaker) -> AppState {
        let appState = AppState(
            speakerClientFactory: MenuUITestSpeakerFactory(speaker: speaker),
            timing: .menuUITest,
            startImmediately: false
        )
        appState.connect(to: speaker.host)
        return appState
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "Condition was not met before timeout")
    }

    private func resetDefaults() {
        let defaults = UserDefaults.standard
        for key in [
            "hasCompletedOnboarding",
            "lastConnectedHost",
            "manualIP",
            "trustedSpeakerHosts",
            "useAutoDiscovery",
            "volumeKeyRoutingMode",
            "volumeKeyRoutingSources",
        ] {
            defaults.removeObject(forKey: key)
        }
    }
}

private struct MenuUITestSpeakerFactory: KEFSpeakerClientFactory {
    let speaker: MenuUITestSpeaker

    func makeClient(host: String) -> KEFSpeakerClient {
        speaker
    }
}

private final class MenuUITestSpeaker: KEFSpeakerClient, @unchecked Sendable {
    let host = "speaker-kitchen.local"
    var playerState = PlayerState(
        isPlaying: true,
        nowPlaying: NowPlayingInfo(title: "Track", artist: "Artist", album: nil)
    )
    var nextTrackError: Error?
    var connectionValidationError: Error?

    func getSnapshot() async throws -> SpeakerSnapshot {
        SpeakerSnapshot(status: .powerOn, source: .wifi, volume: 35, name: "Kitchen", model: "LSXII")
    }

    func getStatus() async throws -> SpeakerStatus { .powerOn }
    func getSource() async throws -> SpeakerSource { .wifi }
    func getVolume() async throws -> Int { 35 }
    func getSpeakerName() async throws -> String { "Kitchen" }
    func getModel() async throws -> String { "LSXII" }
    func getPlayerState() async throws -> PlayerState { playerState }
    func getIsPlaying() async throws -> Bool { playerState.isPlaying }
    func getNowPlayingInfo() async throws -> NowPlayingInfo { playerState.nowPlaying }
    func setVolume(_ volume: Int) async throws {}
    func setSource(_ source: SpeakerSource) async throws {}
    func powerOn() async throws {}
    func shutdown() async throws {}
    func togglePlayPause() async throws {}

    func nextTrack() async throws {
        await Task.yield()
        if let nextTrackError {
            throw nextTrackError
        }
    }

    func previousTrack() async throws {}

    func validateConnection() async throws {
        if let connectionValidationError {
            throw connectionValidationError
        }
    }

    func testConnection() async -> Bool { true }
}

private extension SpeakerTimingPolicy {
    static let menuUITest = SpeakerTimingPolicy(
        autoDiscoveryTimeout: .seconds(0),
        autoDiscoveryPollInterval: .seconds(0),
        connectionRetryDelays: [.seconds(0)],
        stateRefreshPollInterval: .seconds(0),
        pendingVolumeRetention: .seconds(0),
        volumeCommandCoalescingWindow: .seconds(0),
        postVolumeRefreshDelay: .seconds(0),
        sourceVolumeSettleDelay: .seconds(0),
        trackRefreshDelay: .seconds(0),
        wakePollInterval: .seconds(0),
        wakeAttemptCount: 0,
        sleep: { _ in await Task.yield() }
    )
}
