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

    func testReturningUserKeepsRetryingSavedSpeakerDuringTransientLocalNetworkDenial() async {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        let speaker = MenuUITestSpeaker()
        UserDefaults.standard.set(speaker.host, forKey: "lastConnectedHost")
        UserDefaults.standard.set(speaker.host, forKey: "trustedSpeakerHosts")
        speaker.connectionValidationFailuresRemaining = 3
        speaker.connectionValidationFailure = URLError(.notConnectedToInternet)
        let appState = AppState(
            speakerClientFactory: MenuUITestSpeakerFactory(speaker: speaker),
            timing: .reconnectMenuUITest,
            startImmediately: false
        )

        appState.startConnectionForReturningUserIfNeeded()
        appState.discovery.localNetworkAccessDeniedHandler?()

        await waitUntil { appState.isConnected }
        XCTAssertEqual(speaker.connectionValidationAttemptCount, 4)
        XCTAssertEqual(appState.currentHost, speaker.host)
        XCTAssertFalse(appState.needsLocalNetworkAccess)
        XCTAssertNil(appState.connectionError)
    }

    func testSavedSpeakerRecoversAfterDiscoveryWindowExpires() async {
        let speaker = MenuUITestSpeaker()
        speaker.connectionValidationFailuresRemaining = 4
        UserDefaults.standard.set(speaker.host, forKey: "lastConnectedHost")
        UserDefaults.standard.set(speaker.host, forKey: "trustedSpeakerHosts")
        let appState = AppState(
            speakerClientFactory: MenuUITestSpeakerFactory(speaker: speaker),
            timing: .menuUITest,
            startImmediately: false
        )
        defer { appState.disconnect() }

        appState.startConnection()

        await waitUntil { appState.isConnected }
        XCTAssertEqual(speaker.connectionValidationAttemptCount, 5)
        XCTAssertNil(appState.connectionError)
    }

    func testSelectedSpeakerRetriesUntilRecoveryAndDisconnectCancelsRetries() async {
        let speaker = MenuUITestSpeaker()
        speaker.connectionValidationFailuresRemaining = 4
        let appState = AppState(
            speakerClientFactory: MenuUITestSpeakerFactory(speaker: speaker),
            timing: .menuUITest,
            startImmediately: false
        )
        defer { appState.disconnect() }

        appState.connect(to: speaker.host)
        await waitUntil { appState.isConnected }

        speaker.connectionValidationError = URLError(.timedOut)
        appState.connect(to: speaker.host)
        await waitUntil { appState.connectionError != nil }
        XCTAssertEqual(appState.currentHost, speaker.host)
        appState.disconnect()
        let attempts = speaker.connectionValidationAttemptCount
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(speaker.connectionValidationAttemptCount, attempts)
        XCTAssertNil(appState.currentHost)
        XCTAssertFalse(appState.isReconnecting)
    }

    func testTrustedDiscoveredHostnameRecoversWhenSavedIPAddressIsStale() async {
        let stale = MenuUITestSpeaker(host: "10.1.1.222")
        stale.connectionValidationError = URLError(.cannotConnectToHost)
        let recovered = MenuUITestSpeaker()
        recovered.connectionValidationFailuresRemaining = 3
        UserDefaults.standard.set(stale.host, forKey: "lastConnectedHost")
        UserDefaults.standard.set("\(stale.host)\n\(recovered.host)", forKey: "trustedSpeakerHosts")
        let appState = AppState(
            speakerClientFactory: MenuUITestSpeakerFactory(speaker: stale, alternateSpeaker: recovered),
            timing: .menuUITest, startImmediately: false
        )
        defer { appState.disconnect() }
        appState.startConnection()
        appState.discovery.speakers = [
            DiscoveredSpeaker(id: recovered.host, name: "Kitchen", host: recovered.host, macAddress: nil),
        ]

        await waitUntil { appState.isConnected }
        XCTAssertEqual(appState.currentHost, recovered.host)
        XCTAssertEqual(recovered.connectionValidationAttemptCount, 4)
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

        await appState.refresh()

        XCTAssertEqual(appState.actionError, "Next track is unavailable")
    }

    func testRecoveredNetworkActionFailureClearsAfterHealthySnapshot() async {
        let speaker = MenuUITestSpeaker()
        speaker.nextTrackError = URLError(.networkConnectionLost)
        speaker.testConnectionResult = false
        let appState = makeConnectedAppState(speaker: speaker)
        // Connection is announced before the initial snapshot/player refresh
        // completes. Wait for that refresh so it cannot clear the test error.
        await waitUntil { appState.nowPlaying?.title == "Track" }

        appState.nextTrack()

        await waitUntil { !appState.isBusy }
        XCTAssertNotNil(appState.actionError)

        speaker.testConnectionResult = true
        await appState.refresh()

        XCTAssertNil(appState.actionError)
        XCTAssertTrue(appState.isConnected)
    }

    func testStateChangeTimeoutSurfacesActionError() async {
        let speaker = MenuUITestSpeaker()
        let appState = makeConnectedAppState(speaker: speaker)
        // Commands become available after the initial snapshot confirms power.
        await waitUntil { appState.isConnected && appState.status == .powerOn }

        appState.setSource(.tv)

        XCTAssertTrue(appState.isBusy)
        await waitUntil { !appState.isBusy }
        XCTAssertEqual(
            appState.actionError,
            "The speaker did not confirm the requested change in time."
        )
        XCTAssertEqual(appState.source, .wifi)
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
        defer { appState.disconnect() }

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
    var alternateSpeaker: MenuUITestSpeaker? = nil

    func makeClient(host: String) -> KEFSpeakerClient {
        if let alternateSpeaker, alternateSpeaker.host == host { return alternateSpeaker }
        return speaker
    }
}

private final class MenuUITestSpeaker: KEFSpeakerClient, @unchecked Sendable {
    let host: String
    init(host: String = "speaker-kitchen.local") { self.host = host }
    var playerState = PlayerState(
        isPlaying: true,
        nowPlaying: NowPlayingInfo(title: "Track", artist: "Artist", album: nil)
    )
    var nextTrackError: Error?
    var connectionValidationError: Error?
    var connectionValidationFailure: Error = URLError(.networkConnectionLost)
    var connectionValidationFailuresRemaining = 0
    private(set) var connectionValidationAttemptCount = 0
    var testConnectionResult = true

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
        connectionValidationAttemptCount += 1
        if connectionValidationFailuresRemaining > 0 {
            connectionValidationFailuresRemaining -= 1
            throw connectionValidationFailure
        }
        if let connectionValidationError {
            throw connectionValidationError
        }
    }

    func testConnection() async -> Bool { testConnectionResult }
}

private extension SpeakerTimingPolicy {
    static var reconnectMenuUITest: SpeakerTimingPolicy {
        var timing = menuUITest
        timing.autoDiscoveryTimeout = .milliseconds(50)
        return timing
    }

    static let menuUITest = SpeakerTimingPolicy(
        autoDiscoveryTimeout: .seconds(0),
        autoDiscoveryPollInterval: .seconds(0),
        connectionRetryDelays: [.seconds(0)],
        stateRefreshPollInterval: .seconds(0),
        stateChangeTimeout: .milliseconds(25),
        playbackStateChangeTimeout: .milliseconds(25),
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
