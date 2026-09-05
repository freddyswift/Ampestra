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
    @Published var isReconnecting = false
    @Published var needsLocalNetworkAccess = false
    @Published var hasStartedConnection = false

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
    @AppStorage("lastConnectedHost") var lastConnectedHost: String = ""
    @AppStorage("trustedSpeakerHosts") var trustedSpeakerHostsStorage: String = ""

    // Discovery
    let discovery = KEFDiscovery()

    // Internal controllers and task state. `AppState` remains the app-facing
    // coordinator, but long-lived loops and pure policies live in smaller types.
    var speaker: KEFSpeakerClient?
    let connectionSession = SpeakerConnectionSession()
    private var busyActionTask: Task<Void, Never>?
    private var busyActionGeneration = 0
    private var pendingCommittedVolume: Int?
    private var pendingVolumeResetTask: Task<Void, Never>?
    private var volumeBeforeMediaKeyMute: Int?
    private var clearsActionErrorAfterHealthyRefresh = false
    let speakerClientFactory: any KEFSpeakerClientFactory
    let timing: SpeakerTimingPolicy
    private let volumeCommandCoordinator = VolumeCommandCoordinator()
    private let volumePreferenceStore: SpeakerVolumePreferenceStore
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
        volumePreferenceStore: SpeakerVolumePreferenceStore? = nil,
        startImmediately: Bool = true
    ) {
        self.speakerClientFactory = speakerClientFactory
        self.timing = timing
        self.volumePreferenceStore = volumePreferenceStore ?? SpeakerVolumePreferenceStore()

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

    var speakerVolumePreferences: SpeakerVolumePreferences {
        volumePreferenceStore.preferences(host: currentHost, macAddress: speakerMAC)
    }

    var maximumSpeakerVolume: Int {
        speakerVolumePreferences.effectiveMaximumVolume
    }

    func setSpeakerVolumePreferences(_ preferences: SpeakerVolumePreferences) {
        guard currentHost != nil else { return }
        objectWillChange.send()
        volumePreferenceStore.save(preferences, host: currentHost, macAddress: speakerMAC)
        // Replace queued writes that would exceed a newly lowered ceiling.
        if let pendingCommittedVolume, pendingCommittedVolume > maximumSpeakerVolume {
            commitVolume(maximumSpeakerVolume, applyingStepPolicy: false)
        }
    }

    func applyVolumePreset(_ preset: VolumePreset) {
        guard isConnected, status == .powerOn, !isBusy else { return }
        commitVolume(preset.volume, applyingStepPolicy: false)
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

    func updateIfChanged<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppState, Value>, _ newValue: Value) {
        if self[keyPath: keyPath] != newValue {
            self[keyPath: keyPath] = newValue
        }
    }

    /// Poll rapidly until the expected condition is met, or throw on timeout.
    private func waitForState(timeout: Duration, condition: @escaping () -> Bool) async throws {
        if condition() { return }

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            try Task.checkCancellation()
            try await timing.sleep(timing.stateRefreshPollInterval)
            await refresh()
            if condition() { return }
        }

        throw SpeakerActionError.stateChangeTimedOut
    }

    // MARK: - Actions

    private func runBusySpeakerAction(
        _ action: @escaping @MainActor (KEFSpeakerClient) async throws -> Void
    ) {
        guard let speaker, !isBusy else { return }

        clearActionError()
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
                self.clearActionError()
            } catch is CancellationError {
                return
            } catch {
                await self.handleSpeakerActionError(error, for: speaker)
            }
        }
    }

    private func handleSpeakerActionError(_ error: Error, for speaker: KEFSpeakerClient) async {
        guard self.speaker === speaker else { return }
        clearsActionErrorAfterHealthyRefresh = Self.isRecoverableNetworkActionError(error)
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
        let normalizedVolume = applyingStepPolicy
            ? volumePolicy.normalizedVolume(newVolume)
            : VolumePolicy.clampedVolume(newVolume)
        let clampedVolume = speakerVolumePreferences.clampedVolume(normalizedVolume)
        clearActionError()
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
            normalizeBeforeSending: { [volumePreferenceStore, host = currentHost, mac = speakerMAC] value in
                volumePreferenceStore.preferences(host: host, macAddress: mac).clampedVolume(value)
            },
            didSendLatest: { [weak self] speaker in
                guard let self, self.speaker === speaker else { return }
                self.clearActionError()
                await self.refresh()
            },
            didFailLatest: { [weak self] error, speaker in
                guard let self, self.speaker === speaker else { return }
                self.clearPendingVolume()
                await self.handleSpeakerActionError(error, for: speaker)
            }
        )
    }

    func clearRecoveredNetworkActionError() {
        guard clearsActionErrorAfterHealthyRefresh else { return }
        clearActionError()
    }

    private func clearActionError() {
        clearsActionErrorAfterHealthyRefresh = false
        updateIfChanged(\.actionError, nil)
    }

    private nonisolated static func isRecoverableNetworkActionError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }

        switch urlError.code {
        case .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .networkConnectionLost,
             .notConnectedToInternet,
             .resourceUnavailable,
             .timedOut:
            return true
        default:
            return false
        }
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
        clearPendingVolume()

        runBusySpeakerAction { speaker in
            try await speaker.setSource(newSource)
            try await self.waitForState(timeout: self.timing.stateChangeTimeout) {
                self.source == newSource
            }
            // Speaker may take a moment to settle the per-source volume
            try await self.timing.sleep(self.timing.sourceVolumeSettleDelay)
            await self.refresh()
        }
    }

    func togglePower() {
        guard status.allowsPowerToggle else { return }
        let wasPoweredOn = status == .powerOn

        runBusySpeakerAction { speaker in
            if wasPoweredOn {
                try await speaker.shutdown()
                try await self.waitForState(timeout: self.timing.stateChangeTimeout) {
                    self.status == .standby
                }
            } else {
                try await speaker.powerOn()
                try await self.waitForState(timeout: self.timing.stateChangeTimeout) {
                    self.status == .powerOn
                }
            }
        }
    }

    func togglePlayPause() {
        let wasPlaying = isPlaying

        runBusySpeakerAction { speaker in
            try await speaker.togglePlayPause()
            try await self.waitForState(timeout: self.timing.playbackStateChangeTimeout) {
                self.isPlaying != wasPlaying
            }
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
    func syncDisplayedVolume(with remoteVolume: Int) {
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


    // MARK: - Wake action

    func wakeSpeaker() {
        guard !isBusy, let mac = speakerMAC,
              let host = currentHost ?? preferredWakeHost else { return }
        isBusy = true
        busyActionGeneration += 1
        let generation = busyActionGeneration
        busyActionTask = Task {
            defer {
                if busyActionGeneration == generation {
                    isBusy = false
                    busyActionTask = nil
                }
            }
            guard !Task.isCancelled else { return }
            guard sendWakeOnLAN(macAddress: mac) else {
                connectionError = "Could not send the wake request"
                return
            }
            for _ in 0..<timing.wakeAttemptCount {
                try? await timing.sleep(timing.wakePollInterval)
                guard !Task.isCancelled else { return }
                let api = speakerClientFactory.makeClient(host: host)
                let isReachable = await api.testConnection()
                guard !Task.isCancelled, busyActionGeneration == generation else { return }
                if isReachable {
                    connect(to: host)
                    return
                }
            }
            connectionError = "Speaker did not wake up"
        }
    }


    /// Connection teardown invalidates every action before a new speaker can run.
    func resetSpeakerActionState() {
        busyActionGeneration += 1
        busyActionTask?.cancel()
        busyActionTask = nil
        volumeCommandCoordinator.cancel()
        updateIfChanged(\.speakerName, "")
        updateIfChanged(\.speakerModel, "")
        updateIfChanged(\.status, .standby)
        updateIfChanged(\.source, .wifi)
        updateIfChanged(\.volume, 0)
        updateIfChanged(\.displayedVolume, 0)
        volumeBeforeMediaKeyMute = nil
        updateIfChanged(\.isPlaying, false)
        updateIfChanged(\.nowPlaying, nil)
        clearActionError()
        updateIfChanged(\.isBusy, false)
        clearPendingVolume(keepDisplayedVolume: false)
        volumeHUD.hide()
    }

}
