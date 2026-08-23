import AppKit
import Combine
import KEFCore
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    /// Media-key permissions are modeled separately from the chosen routing
    /// mode. A user can request KEF routing while macOS still blocks the event
    /// tap, so the UI needs to represent both preference and permission state.
    enum MediaKeyAccessState: Equatable {
        case unknown
        case working
        case inputMonitoringNeeded
        case inputMonitoringDenied
        case accessibilityNeeded
        case accessibilityDenied
        case failedToActivate
    }

    // Connection
    @Published var isConnected = false
    @Published var connectionError: String?
    @Published var currentHost: String?
    @Published private(set) var isReconnecting = false
    @Published private(set) var needsLocalNetworkAccess = false
    @Published private(set) var hasStartedConnection = false

    // Speaker state
    @Published var speakerName: String = ""
    @Published var speakerModel: String = ""
    @Published var status: SpeakerStatus = .standby
    @Published var source: SpeakerSource = .wifi
    @Published var volume: Int = 0
    @Published private(set) var displayedVolume: Int = 0
    @Published var isPlaying = false
    @Published var nowPlaying: NowPlayingInfo?
    @Published private(set) var actionError: String?

    // Busy state — set during actions that take time to reflect
    @Published var isBusy = false

    // Settings (persisted)
    @AppStorage("manualIP") var manualIP: String = ""
    @AppStorage("useAutoDiscovery") var useAutoDiscovery: Bool = true
    @AppStorage("volumeKeyRoutingMode") var volumeKeyRoutingMode: VolumeKeyRoutingMode = .mac {
        didSet {
            if oldValue != volumeKeyRoutingMode {
                objectWillChange.send()
            }
            refreshMediaKeyAccessStatus()
        }
    }
    @AppStorage("volumeKeyRoutingSources") private var storedVolumeKeyRoutingSources: String =
        SpeakerSource.inputSources.map(\.rawValue).joined(separator: ",")
    @AppStorage("useFixedVolumeSteps") private var storedUseFixedVolumeSteps: Bool = true
    @AppStorage("volumeStepSize") private var storedVolumeStepSize: Int = 5
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false
    @AppStorage("lastConnectedHost") private var lastConnectedHost: String = ""
    @AppStorage("trustedSpeakerHosts") private var trustedSpeakerHostsStorage: String = ""

    // Discovery
    let discovery = KEFDiscovery()

    // Internal controllers and task state. `AppState` remains the app-facing
    // coordinator, but long-lived loops and pure policies live in smaller types.
    private var speaker: KEFSpeakerClient?
    private var connectionTask: Task<Void, Never>?
    private var busyActionTask: Task<Void, Never>?
    private var busyActionGeneration = 0
    private let pollingController = SpeakerPollingController()
    private var isRefreshInProgress = false
    private var needsTrailingRefresh = false
    private var lastPlaybackStateRefresh: ContinuousClock.Instant?
    private var consecutiveRefreshFailures = 0
    private var pendingCommittedVolume: Int?
    private var pendingVolumeResetTask: Task<Void, Never>?
    private var volumeBeforeMediaKeyMute: Int?
    private let speakerClientFactory: any KEFSpeakerClientFactory
    private let timing: SpeakerTimingPolicy
    private let volumeCommandCoordinator = VolumeCommandCoordinator()
    private var discoveryObservation: AnyCancellable?
    private var hasRequestedMediaKeyAccess = false
    private var hasRequestedAccessibilityAccess = false
    private let volumeHUD = VolumeHUDController()
    private var isVolumeHUDSuppressed = false
    private lazy var mediaKeyController = MediaKeyController(
        onVolumeDelta: { [weak self] delta in
            self?.handleVolumeKey(delta) ?? false
        },
        onMuteToggle: { [weak self] in
            self?.handleMuteKey() ?? false
        }
    )

    @Published private(set) var mediaKeyAccessState: MediaKeyAccessState = .unknown
    @Published private(set) var mediaKeyAccessMessage = ""
    @Published private(set) var needsRestartForMediaKeyAccess = false

    private var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Ampestra"
    }

    init(
        speakerClientFactory: any KEFSpeakerClientFactory = LiveKEFSpeakerClientFactory(),
        timing: SpeakerTimingPolicy = .live,
        startImmediately: Bool = true
    ) {
        self.speakerClientFactory = speakerClientFactory
        self.timing = timing

        migrateLegacyVolumeKeyPreference()
        discovery.localNetworkAccessDeniedHandler = { [weak self] in
            self?.handleLocalNetworkAccessDenied()
        }
        discoveryObservation = discovery.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        refreshMediaKeyAccessStatus()
        if startImmediately {
            startConnection()
        }
    }

    var allowedVolumeStepRange: ClosedRange<Int> {
        VolumePolicy.allowedStepRange
    }

    var useFixedVolumeSteps: Bool {
        storedUseFixedVolumeSteps
    }

    var volumeStepSize: Int {
        Self.clampedVolumeStep(storedVolumeStepSize)
    }

    var effectiveVolumeStep: Int {
        useFixedVolumeSteps ? volumeStepSize : 1
    }

    var volumeSliderStep: Double {
        Double(effectiveVolumeStep)
    }

    var volumeKeyRoutingSources: Set<SpeakerSource> {
        Set(
            storedVolumeKeyRoutingSources
                .split(separator: ",")
                .compactMap { SpeakerSource(rawValue: String($0)) }
        )
    }

    var requiresMediaKeyAccess: Bool {
        volumeKeyRoutingPolicy.requiresMediaKeyAccess
    }

    var usesDefaultControlPreferences: Bool {
        useFixedVolumeSteps
            && volumeStepSize == 5
            && volumeKeyRoutingMode == .mac
            && volumeKeyRoutingSources == Set(SpeakerSource.inputSources)
    }

    func setUseFixedVolumeSteps(_ enabled: Bool) {
        guard storedUseFixedVolumeSteps != enabled else { return }
        objectWillChange.send()
        storedUseFixedVolumeSteps = enabled
    }

    func setVolumeStepSize(_ step: Int) {
        let clampedStep = Self.clampedVolumeStep(step)
        guard storedVolumeStepSize != clampedStep else { return }
        objectWillChange.send()
        storedVolumeStepSize = clampedStep
    }

    func routesVolumeKeysToSpeaker(on source: SpeakerSource) -> Bool {
        volumeKeyRoutingSources.contains(source)
    }

    func setVolumeKeyRoutingEnabled(_ enabled: Bool, for source: SpeakerSource) {
        var sources = volumeKeyRoutingSources
        if enabled {
            sources.insert(source)
        } else {
            sources.remove(source)
        }

        let encodedSources = SpeakerSource.inputSources
            .filter { sources.contains($0) }
            .map(\.rawValue)
            .joined(separator: ",")
        guard storedVolumeKeyRoutingSources != encodedSources else { return }

        objectWillChange.send()
        storedVolumeKeyRoutingSources = encodedSources
        refreshMediaKeyAccessStatus()
    }

    func resetControlPreferences() {
        setUseFixedVolumeSteps(true)
        setVolumeStepSize(5)
        objectWillChange.send()
        storedVolumeKeyRoutingSources = SpeakerSource.inputSources
            .map(\.rawValue)
            .joined(separator: ",")
        volumeKeyRoutingMode = .mac
    }

    private static func clampedVolumeStep(_ step: Int) -> Int {
        VolumePolicy.clampedStepSize(step)
    }

    private var volumePolicy: VolumePolicy {
        VolumePolicy(usesFixedSteps: useFixedVolumeSteps, stepSize: volumeStepSize)
    }

    private var volumeKeyRoutingPolicy: VolumeKeyRoutingPolicy {
        VolumeKeyRoutingPolicy(
            mode: volumeKeyRoutingMode,
            speakerSources: volumeKeyRoutingSources
        )
    }

    func setVolumeHUDSuppressed(_ suppressed: Bool) {
        guard isVolumeHUDSuppressed != suppressed else { return }
        isVolumeHUDSuppressed = suppressed
        if suppressed {
            volumeHUD.hide()
        }
    }

    func refreshMediaKeyAccessStatus() {
        guard requiresMediaKeyAccess else {
            mediaKeyController.invalidate()
            setMediaKeyAccessState(
                .unknown,
                message: "Volume keys will control macOS system volume."
            )
            return
        }

        guard MediaKeyController.hasListenAccess else {
            mediaKeyController.invalidate()
            setMediaKeyAccessState(
                hasRequestedMediaKeyAccess ? .inputMonitoringDenied : .inputMonitoringNeeded,
                message: hasRequestedMediaKeyAccess
                    ? "Turn on \(appDisplayName) in Input Monitoring, then return here."
                    : "macOS grants broad key-listening access; \(appDisplayName) uses it only for volume media keys."
            )
            return
        }

        guard MediaKeyController.hasAccessibilityAccess else {
            mediaKeyController.invalidate()
            setMediaKeyAccessState(
                hasRequestedAccessibilityAccess ? .accessibilityDenied : .accessibilityNeeded,
                message: hasRequestedAccessibilityAccess
                    ? "Turn on \(appDisplayName) in Accessibility, then return here."
                    : "\(appDisplayName) uses Accessibility only to intercept volume keys before macOS changes Mac volume."
            )
            return
        }

        switch mediaKeyController.activate() {
        case .working:
            setMediaKeyAccessState(.working, message: "Ready.")
        case .missingAccessibility:
            mediaKeyController.invalidate()
            setMediaKeyAccessState(
                hasRequestedAccessibilityAccess ? .accessibilityDenied : .accessibilityNeeded,
                message: hasRequestedAccessibilityAccess
                    ? "Turn on \(appDisplayName) in Accessibility, then return here."
                    : "\(appDisplayName) uses Accessibility only to intercept volume keys before macOS changes Mac volume."
            )
        case .failed:
            setMediaKeyAccessState(
                .failedToActivate,
                message: "macOS refused the listener. Restart or re-add permissions.",
                needsRestart: true
            )
        }
    }

    private func setMediaKeyAccessState(
        _ state: MediaKeyAccessState,
        message: String,
        needsRestart: Bool = false
    ) {
        updateIfChanged(\.mediaKeyAccessState, state)
        updateIfChanged(\.mediaKeyAccessMessage, message)
        updateIfChanged(\.needsRestartForMediaKeyAccess, needsRestart)
    }

    func requestMediaKeyAccess() {
        guard requiresMediaKeyAccess else {
            refreshMediaKeyAccessStatus()
            return
        }

        if !MediaKeyController.hasListenAccess {
            hasRequestedMediaKeyAccess = true
            MediaKeyController.requestListenAccess()
        } else if !MediaKeyController.hasAccessibilityAccess {
            hasRequestedAccessibilityAccess = true
            MediaKeyController.requestAccessibilityAccess()
        } else {
            mediaKeyController.invalidate()
        }

        refreshMediaKeyAccessStatus()
    }

    func completeOnboarding() {
        guard !hasCompletedOnboarding else { return }
        hasCompletedOnboarding = true
    }

    var shouldShowOnboarding: Bool {
        if hasCompletedOnboarding {
            return false
        }

        return !isConnected
    }

    func openInputMonitoringSettings() {
        openPrivacySettings(anchor: "Privacy_ListenEvent")
    }

    func openAccessibilitySettings() {
        openPrivacySettings(anchor: "Privacy_Accessibility")
    }

    func openLocalNetworkSettings() {
        openPrivacySettings(anchor: "Privacy_LocalNetwork")
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.promptsUserIfNeeded = true

        // A MenuBarExtra window can retain activation while Launch Services
        // opens System Settings behind it. Close our transient panel first,
        // then activate Settings again after its destination window exists.
        NSApp.keyWindow?.orderOut(nil)
        NSApp.deactivate()

        NSWorkspace.shared.open(url, configuration: configuration) { runningApplication, _ in
            if let runningApplication {
                Self.bringSystemSettingsToFront(runningApplication)
                return
            }

            let settingsURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")
            let fallbackConfiguration = NSWorkspace.OpenConfiguration()
            fallbackConfiguration.activates = true
            NSWorkspace.shared.openApplication(
                at: settingsURL,
                configuration: fallbackConfiguration
            ) { fallbackApplication, _ in
                guard let fallbackApplication else { return }
                Self.bringSystemSettingsToFront(fallbackApplication)
            }
        }
    }

    private nonisolated static func bringSystemSettingsToFront(_ application: NSRunningApplication) {
        for delay in [0.0, 0.35, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                application.unhide()
                application.activate(options: [.activateAllWindows])
            }
        }
    }

    func restartApp() {
        let bundleURL = Bundle.main.bundleURL

        if bundleURL.pathExtension == "app" {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", "sleep 0.4; /usr/bin/open \(shellQuoted(bundleURL.path))"]
            try? task.run()
        }

        NSApplication.shared.terminate(nil)
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    // MARK: - Connection

    func startConnectionIfNeeded() {
        guard !hasStartedConnection, !isConnected, !isReconnecting else { return }
        startConnection()
    }

    func startConnectionForReturningUserIfNeeded() {
        guard hasCompletedOnboarding else { return }
        startConnectionIfNeeded()
    }

    func scanForSpeakers() {
        updateIfChanged(\.hasStartedConnection, true)
        updateIfChanged(\.needsLocalNetworkAccess, false)
        if !isConnected {
            updateIfChanged(\.connectionError, nil)
        }
        discovery.startDiscovery()
    }

    func startConnection() {
        updateIfChanged(\.hasStartedConnection, true)
        updateIfChanged(\.needsLocalNetworkAccess, false)
        disconnect()

        let manualHost = manualIP.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manualHost.isEmpty {
            connect(to: manualHost)
            return
        }

        guard useAutoDiscovery else { return }

        discovery.startDiscovery()
        connectionTask = Task { @MainActor in
            var attemptedHosts = Set<String>()

            if let trustedLastConnectedHost = trustedHostForAutoConnection(lastConnectedHost) {
                attemptedHosts.insert(trustedLastConnectedHost)
                if await establishConnection(to: trustedLastConnectedHost, retryCount: 2, trustOnSuccess: true) {
                    return
                }
            }

            let deadline = ContinuousClock.now + timing.autoDiscoveryTimeout
            while ContinuousClock.now < deadline {
                guard !Task.isCancelled else { return }

                let candidates = trustedAutoConnectionCandidates(from: discovery.speakers)
                    .filter { !attemptedHosts.contains($0) }

                for host in candidates {
                    attemptedHosts.insert(host)
                    if await establishConnection(to: host, retryCount: 2, trustOnSuccess: true) {
                        return
                    }
                }

                try? await timing.sleep(timing.autoDiscoveryPollInterval)
            }

            guard !Task.isCancelled else { return }
            discovery.stopDiscovery()
            if speaker == nil {
                updateIfChanged(\.isConnected, false)
                updateIfChanged(\.isReconnecting, false)
                updateIfChanged(\.connectionError, discovery.speakers.isEmpty
                    ? "No KEF speaker found"
                    : "Choose a discovered speaker to connect")
            }
        }
    }

    func connect(to host: String) {
        updateIfChanged(\.hasStartedConnection, true)
        updateIfChanged(\.needsLocalNetworkAccess, false)
        disconnect()

        guard let normalizedHost = ManualHostValidator.normalizedHost(host) else {
            connectionError = "Enter a private local IP address or .local host."
            return
        }

        connectionTask = Task { @MainActor in
            let connected = await establishConnection(to: normalizedHost, retryCount: 3, trustOnSuccess: true)
            guard !Task.isCancelled else { return }

            if !connected {
                updateIfChanged(\.isConnected, false)
                updateIfChanged(\.isReconnecting, false)
                if connectionError == nil {
                    connectionError = "Cannot reach speaker at \(normalizedHost)"
                }
                speaker = nil
                currentHost = nil
            }
        }
    }

    func disconnect() {
        connectionTask?.cancel()
        connectionTask = nil
        busyActionGeneration += 1
        busyActionTask?.cancel()
        busyActionTask = nil
        discovery.stopDiscovery()
        pollingController.stop()
        volumeCommandCoordinator.cancel()
        needsTrailingRefresh = false
        lastPlaybackStateRefresh = nil
        speaker = nil
        updateIfChanged(\.isConnected, false)
        updateIfChanged(\.isReconnecting, false)
        updateIfChanged(\.needsLocalNetworkAccess, false)
        updateIfChanged(\.currentHost, nil)
        updateIfChanged(\.connectionError, nil)
        consecutiveRefreshFailures = 0
        updateIfChanged(\.speakerName, "")
        updateIfChanged(\.speakerModel, "")
        updateIfChanged(\.status, .standby)
        updateIfChanged(\.source, .wifi)
        updateIfChanged(\.volume, 0)
        updateIfChanged(\.displayedVolume, 0)
        volumeBeforeMediaKeyMute = nil
        updateIfChanged(\.isPlaying, false)
        updateIfChanged(\.nowPlaying, nil)
        updateIfChanged(\.actionError, nil)
        updateIfChanged(\.isBusy, false)
        clearPendingVolume(keepDisplayedVolume: false)
        volumeHUD.hide()
    }

    func forgetSpeaker(host: String) {
        guard let forgottenHost = ManualHostValidator.normalizedHost(host) else { return }
        let isForgettingCurrentSpeaker = ManualHostValidator.normalizedHost(currentHost ?? "") == forgottenHost

        objectWillChange.send()
        if ManualHostValidator.normalizedHost(manualIP) == forgottenHost {
            manualIP = ""
        }
        removeTrustedHost(forgottenHost)
        if ManualHostValidator.normalizedHost(lastConnectedHost) == forgottenHost {
            lastConnectedHost = ""
        }

        if isForgettingCurrentSpeaker {
            hasCompletedOnboarding = false
            disconnect()
        }
    }

    private var trustedSpeakerHosts: Set<String> {
        get {
            Set(
                trustedSpeakerHostsStorage
                    .split(separator: "\n")
                    .map(String.init)
            )
        }
        set {
            trustedSpeakerHostsStorage = newValue.sorted().joined(separator: "\n")
        }
    }

    private func trustedHostForAutoConnection(_ host: String) -> String? {
        guard let normalizedHost = ManualHostValidator.normalizedHost(host),
              trustedSpeakerHosts.contains(normalizedHost) else {
            return nil
        }

        return normalizedHost
    }

    func trustedAutoConnectionCandidates(from speakers: [DiscoveredSpeaker]) -> [String] {
        speakers.compactMap { trustedHostForAutoConnection($0.host) }
    }

    private func trustSpeakerHost(_ host: String) {
        guard let normalizedHost = ManualHostValidator.normalizedHost(host) else { return }
        var hosts = trustedSpeakerHosts
        guard hosts.insert(normalizedHost).inserted else { return }
        trustedSpeakerHosts = hosts
    }

    private func removeTrustedHost(_ host: String) {
        guard let normalizedHost = ManualHostValidator.normalizedHost(host) else { return }
        var hosts = trustedSpeakerHosts
        hosts.remove(normalizedHost)
        trustedSpeakerHosts = hosts
    }

    @discardableResult
    private func establishConnection(to host: String, retryCount: Int, trustOnSuccess: Bool) async -> Bool {
        let api = speakerClientFactory.makeClient(host: host)
        speaker = api
        updateIfChanged(\.currentHost, host)
        updateIfChanged(\.isReconnecting, true)
        updateIfChanged(\.needsLocalNetworkAccess, false)
        updateIfChanged(\.connectionError, nil)
        var lastConnectionError: Error?

        for attempt in 0..<retryCount {
            guard !Task.isCancelled, self.speaker === api else { return false }

            do {
                try await api.validateConnection()
                guard !Task.isCancelled, self.speaker === api else { return false }
                markConnectionHealthy(for: api, stopDiscovery: true, trustHost: trustOnSuccess)
                await refresh()
                startPolling()
                return true
            } catch {
                lastConnectionError = error
            }

            if attempt < retryCount - 1 {
                try? await timing.sleep(timing.connectionRetryDelay(afterAttempt: attempt))
            }
        }

        guard self.speaker === api else { return false }
        speaker = nil
        updateIfChanged(\.currentHost, nil)
        updateIfChanged(\.isConnected, false)
        updateIfChanged(\.isReconnecting, false)
        if let lastConnectionError {
            applyConnectionFailure(lastConnectionError, host: host)
        }
        return false
    }

    private func applyConnectionFailure(_ error: Error, host: String) {
        if let urlError = error as? URLError, urlError.code == .notConnectedToInternet {
            updateIfChanged(\.needsLocalNetworkAccess, true)
            updateIfChanged(
                \.connectionError,
                "macOS reports that Local Network access is blocked, even though System Settings may show it as enabled."
            )
            return
        }

        updateIfChanged(\.needsLocalNetworkAccess, false)
        updateIfChanged(\.connectionError, "Cannot reach speaker at \(host)")
    }

    private func handleLocalNetworkAccessDenied() {
        connectionTask?.cancel()
        connectionTask = nil
        updateIfChanged(\.needsLocalNetworkAccess, true)
        updateIfChanged(\.isReconnecting, false)
        updateIfChanged(
            \.connectionError,
            "macOS reports that Local Network access is blocked, even though System Settings may show it as enabled."
        )
    }

    // MARK: - Polling

    private func startPolling() {
        pollingController.start(
            refresh: { [weak self] in
                await self?.refresh()
            },
            isPlaybackStatePollingNeeded: { [weak self] in
                self?.isPlaybackStatePollingNeeded == true
            },
            refreshPlaybackStateForVolumeRouting: { [weak self] in
                await self?.refreshPlaybackStateForVolumeRouting()
            }
        )
    }

    private var isPlaybackStatePollingNeeded: Bool {
        volumeKeyRoutingMode == .auto
            && mediaKeyAccessState == .working
            && volumeKeyRoutingSources.contains(source)
            && source.usesPlaybackStateForVolumeRouting
            && status == .powerOn
    }

    /// Auto routing needs fresher playback state than the full 3-second refresh.
    /// This lightweight poll only runs when the current source uses playback
    /// state to decide whether volume keys should control the speaker or macOS.
    private func refreshPlaybackStateForVolumeRouting() async {
        guard isPlaybackStatePollingNeeded, let speaker else {
            return
        }

        do {
            let playerState = try await speaker.getPlayerState()
            guard self.speaker === speaker else { return }
            applyPlayerState(playerState)
            lastPlaybackStateRefresh = ContinuousClock.now
        } catch {
            guard self.speaker === speaker else { return }
        }
    }

    func refresh() async {
        if isRefreshInProgress {
            needsTrailingRefresh = true
            return
        }

        isRefreshInProgress = true
        defer { isRefreshInProgress = false }

        repeat {
            needsTrailingRefresh = false
            await performRefresh()
        } while needsTrailingRefresh
    }

    private func performRefresh() async {
        guard let speaker else { return }

        do {
            let snapshot = try await speaker.getSnapshot()

            guard self.speaker === speaker else { return }

            updateIfChanged(\.status, snapshot.status)
            updateIfChanged(\.source, snapshot.source)
            updateIfChanged(\.volume, snapshot.volume)
            syncDisplayedVolume(with: snapshot.volume)
            updateIfChanged(\.speakerName, snapshot.name)
            updateIfChanged(\.speakerModel, snapshot.model)

            if snapshot.status == .powerOn,
               snapshot.source.usesPlaybackStateForVolumeRouting,
               !hasFreshPlaybackStateFromRoutingPoll {
                let playerData = try? await speaker.getPlayerState()
                guard self.speaker === speaker else { return }
                if let playerData {
                    applyPlayerState(playerData)
                    lastPlaybackStateRefresh = ContinuousClock.now
                } else {
                    clearPlayerState()
                }
            } else if snapshot.status != .powerOn || !snapshot.source.usesPlaybackStateForVolumeRouting {
                clearPlayerState()
                lastPlaybackStateRefresh = nil
            }

            markConnectionHealthy(for: speaker)
        } catch {
            guard self.speaker === speaker else { return }
            if await speaker.testConnection() {
                markConnectionHealthy(for: speaker)
            } else {
                recordConnectionFailure(for: speaker)
            }
        }
    }

    private var hasFreshPlaybackStateFromRoutingPoll: Bool {
        guard isPlaybackStatePollingNeeded, let lastPlaybackStateRefresh else {
            return false
        }

        return lastPlaybackStateRefresh.duration(to: ContinuousClock.now) < .seconds(2)
    }

    private func applyPlayerState(_ playerState: PlayerState) {
        updateIfChanged(\.isPlaying, playerState.isPlaying)
        updateIfChanged(\.nowPlaying, playerState.nowPlaying.hasInfo ? playerState.nowPlaying : nil)
    }

    private func clearPlayerState() {
        updateIfChanged(\.isPlaying, false)
        updateIfChanged(\.nowPlaying, nil)
    }

    private func markConnectionHealthy(
        for speaker: KEFSpeakerClient,
        stopDiscovery: Bool = false,
        trustHost: Bool = false
    ) {
        guard self.speaker === speaker else { return }

        consecutiveRefreshFailures = 0
        updateIfChanged(\.isConnected, true)
        updateIfChanged(\.isReconnecting, false)
        updateIfChanged(\.currentHost, speaker.host)
        if trustHost {
            trustSpeakerHost(speaker.host)
            if lastConnectedHost != speaker.host {
                lastConnectedHost = speaker.host
            }
        }
        updateIfChanged(\.connectionError, nil)
        updateIfChanged(\.needsLocalNetworkAccess, false)
        if stopDiscovery {
            discovery.stopDiscovery()
        }
    }

    private func recordConnectionFailure(for speaker: KEFSpeakerClient) {
        guard self.speaker === speaker else { return }

        consecutiveRefreshFailures += 1

        if consecutiveRefreshFailures >= 3 || !isConnected {
            updateIfChanged(\.isConnected, false)
            updateIfChanged(\.isReconnecting, true)
            updateIfChanged(\.connectionError, "Reconnecting to speaker...")
        }
    }

    private func updateIfChanged<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppState, Value>, _ newValue: Value) {
        if self[keyPath: keyPath] != newValue {
            self[keyPath: keyPath] = newValue
        }
    }

    /// Poll rapidly until the expected condition is met, or timeout.
    private func waitForState(timeout: Duration = .seconds(8), condition: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await timing.sleep(timing.stateRefreshPollInterval)
            await refresh()
            if condition() { return }
        }
    }

    // MARK: - Actions

    private func runBusySpeakerAction(
        _ action: @escaping @MainActor (KEFSpeakerClient) async throws -> Void
    ) {
        guard let speaker, !isBusy else { return }

        updateIfChanged(\.actionError, nil)
        updateIfChanged(\.isBusy, true)
        busyActionGeneration += 1
        let generation = busyActionGeneration

        busyActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.busyActionGeneration == generation {
                    self.busyActionTask = nil
                    self.updateIfChanged(\.isBusy, false)
                }
            }

            do {
                try Task.checkCancellation()
                try await action(speaker)
                try Task.checkCancellation()
                guard self.speaker === speaker else { return }
                self.updateIfChanged(\.actionError, nil)
            } catch is CancellationError {
                return
            } catch {
                await self.handleSpeakerActionError(error, for: speaker)
            }
        }
    }

    private func handleSpeakerActionError(_ error: Error, for speaker: KEFSpeakerClient) async {
        guard self.speaker === speaker else { return }
        updateIfChanged(\.actionError, error.localizedDescription)

        if await speaker.testConnection() {
            markConnectionHealthy(for: speaker)
            await refresh()
        } else {
            recordConnectionFailure(for: speaker)
        }
    }

    func commitVolume(_ newVolume: Int) {
        commitVolume(newVolume, applyingStepPolicy: true)
    }

    private func commitVolume(_ newVolume: Int, applyingStepPolicy: Bool) {
        let clampedVolume = applyingStepPolicy
            ? volumePolicy.normalizedVolume(newVolume)
            : VolumePolicy.clampedVolume(newVolume)
        updateIfChanged(\.actionError, nil)
        if clampedVolume > 0 {
            volumeBeforeMediaKeyMute = nil
        }
        updateIfChanged(\.volume, clampedVolume)
        updateIfChanged(\.displayedVolume, clampedVolume)
        pendingCommittedVolume = clampedVolume
        pendingVolumeResetTask?.cancel()
        pendingVolumeResetTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.timing.sleep(self.timing.pendingVolumeRetention)
            } catch {
                return
            }
            if self.pendingCommittedVolume == clampedVolume {
                self.clearPendingVolume()
            }
        }

        guard let speaker else { return }
        if !isVolumeHUDSuppressed {
            volumeHUD.show(
                title: volumeHUDTitle,
                volume: clampedVolume
            )
        }
        volumeCommandCoordinator.submit(
            volume: clampedVolume,
            speaker: speaker,
            timing: timing,
            didSendLatest: { [weak self] speaker in
                guard let self, self.speaker === speaker else { return }
                self.updateIfChanged(\.actionError, nil)
                await self.refresh()
            },
            didFailLatest: { [weak self] error, speaker in
                guard let self, self.speaker === speaker else { return }
                self.clearPendingVolume()
                await self.handleSpeakerActionError(error, for: speaker)
            }
        )
    }

    private func adjustVolume(by delta: Int) {
        let direction = delta.signum()
        guard direction != 0 else { return }
        commitVolume(volumePolicy.nextVolume(from: displayedVolume, direction: direction))
    }

    private func toggleMute() {
        let result = VolumePolicy.muteToggle(
            from: displayedVolume,
            restoreVolume: volumeBeforeMediaKeyMute
        )
        volumeBeforeMediaKeyMute = result.restoreVolume

        if result.targetVolume != displayedVolume {
            commitVolume(result.targetVolume, applyingStepPolicy: false)
        }
    }

    func toggleSpeakerMute() {
        toggleMute()
    }

    private var volumeHUDTitle: String {
        speakerModel.isEmpty ? speakerName : speakerModel
    }

    func setSource(_ newSource: SpeakerSource) {
        let oldSource = source
        clearPendingVolume()

        runBusySpeakerAction { speaker in
            try await speaker.setSource(newSource)
            try await self.waitForState { self.source == newSource || self.source != oldSource }
            // Speaker may take a moment to settle the per-source volume
            try await self.timing.sleep(self.timing.sourceVolumeSettleDelay)
            await self.refresh()
        }
    }

    func togglePower() {
        let wasPoweredOn = status == .powerOn

        runBusySpeakerAction { speaker in
            if wasPoweredOn {
                try await speaker.shutdown()
                try await self.waitForState { self.status == .standby }
            } else {
                try await speaker.powerOn()
                try await self.waitForState { self.status == .powerOn }
            }
        }
    }

    func togglePlayPause() {
        let wasPlaying = isPlaying

        runBusySpeakerAction { speaker in
            try await speaker.togglePlayPause()
            try await self.waitForState(timeout: .seconds(4)) { self.isPlaying != wasPlaying }
        }
    }

    func nextTrack() {
        runBusySpeakerAction { speaker in
            try await speaker.nextTrack()
            try await self.timing.sleep(self.timing.trackRefreshDelay)
            await self.refresh()
        }
    }

    func previousTrack() {
        runBusySpeakerAction { speaker in
            try await speaker.previousTrack()
            try await self.timing.sleep(self.timing.trackRefreshDelay)
            await self.refresh()
        }
    }

    // MARK: - Volume reconciliation

    /// Keep the UI optimistic after a local volume change. Speakers can report
    /// their old volume for a short period after `setVolume`; this prevents the
    /// slider and HUD from bouncing backward while the command is settling.
    private func syncDisplayedVolume(with remoteVolume: Int) {
        if let pendingCommittedVolume {
            if remoteVolume == pendingCommittedVolume {
                clearPendingVolume()
            } else {
                updateIfChanged(\.displayedVolume, pendingCommittedVolume)
            }
        } else {
            updateIfChanged(\.displayedVolume, remoteVolume)
            if remoteVolume > 0 {
                volumeBeforeMediaKeyMute = nil
            }
        }
    }

    private func clearPendingVolume(keepDisplayedVolume: Bool = true) {
        pendingCommittedVolume = nil
        pendingVolumeResetTask?.cancel()
        pendingVolumeResetTask = nil
        if keepDisplayedVolume {
            updateIfChanged(\.displayedVolume, volume)
        }
    }

    // MARK: - Media keys

    private func handleVolumeKey(_ delta: Int) -> Bool {
        guard shouldRouteVolumeKeysToSpeaker else { return false }
        adjustVolume(by: delta)
        return true
    }

    private func handleMuteKey() -> Bool {
        guard shouldRouteVolumeKeysToSpeaker else { return false }
        toggleMute()
        return true
    }

    private var shouldRouteVolumeKeysToSpeaker: Bool {
        volumeKeyRoutingPolicy.routesToSpeaker(
            isConnected: isConnected,
            status: status,
            source: source,
            isPlaying: isPlaying
        )
    }

    private func migrateLegacyVolumeKeyPreference() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "volumeKeyRoutingMode") == nil,
              let legacyValue = defaults.object(forKey: "useVolumeKeys") as? Bool else {
            return
        }

        volumeKeyRoutingMode = legacyValue ? .auto : .mac
    }

    // MARK: - Wake-on-LAN

    var speakerMAC: String? {
        if let currentHost,
           let mac = discovery.speakers.first(where: { $0.host == currentHost })?.macAddress {
            return mac
        }

        if let mac = discovery.speakers.first(where: { $0.macAddress != nil })?.macAddress {
            return mac
        }

        return nil
    }

    func wakeSpeaker() {
        guard let mac = speakerMAC else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            _ = sendWakeOnLAN(macAddress: mac)
            for _ in 0..<timing.wakeAttemptCount {
                try? await timing.sleep(timing.wakePollInterval)
                guard !Task.isCancelled else { return }
                if let host = currentHost ?? preferredWakeHost {
                    let api = speakerClientFactory.makeClient(host: host)
                    if await api.testConnection() {
                        connect(to: host)
                        return
                    }
                }
            }
            connectionError = "Speaker did not wake up"
        }
    }

    private var preferredWakeHost: String? {
        if let trustedLastConnectedHost = trustedHostForAutoConnection(lastConnectedHost) {
            return trustedLastConnectedHost
        }

        return discovery.speakers
            .compactMap { trustedHostForAutoConnection($0.host) }
            .first
    }
}
