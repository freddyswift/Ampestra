import AppIntents
import Combine
import Foundation
import KEFCore
import WidgetKit

@MainActor
final class RemoteStore: ObservableObject {
    typealias ClientFactory = @Sendable (String) -> KEFSpeakerClient
    typealias Sleep = @Sendable (Duration) async throws -> Void

    @Published private(set) var connectionState: SpeakerConnectionState = .disconnected
    @Published private(set) var currentHost: String?
    @Published private(set) var speakerName = "KEF Speaker"
    @Published private(set) var speakerModel = ""
    @Published private(set) var speakerStatus: SpeakerStatus = .standby
    @Published private(set) var source: SpeakerSource = .wifi
    @Published private(set) var volume = 0
    @Published private(set) var isSendingCommand = false
    @Published private(set) var isAdjustingVolume = false
    @Published private(set) var localNetworkPermissionDenied = false
    @Published private(set) var lastError: String?
    @Published private(set) var notice: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var nowPlaying: NowPlayingInfo?

    @Published var manualHost: String
    @Published var hardwareButtonsEnabled: Bool {
        didSet {
            defaults.set(hardwareButtonsEnabled, forKey: SpeakerPreferenceKeys.hardwareButtonsEnabled)
            updateHardwareButtonCapture()
        }
    }
    @Published var mutePhoneOnExit: Bool {
        didSet {
            defaults.set(mutePhoneOnExit, forKey: SpeakerPreferenceKeys.mutePhoneOnExit)
        }
    }
    @Published var volumeStep: Int {
        didSet {
            let clamped = VolumePolicy.clampedStepSize(volumeStep)
            if volumeStep != clamped {
                volumeStep = clamped
                return
            }
            defaults.set(clamped, forKey: SpeakerPreferenceKeys.volumeStep)
            WidgetCenter.shared.reloadTimelines(ofKind: AmpestraWidgetConstants.controlsKind)
        }
    }

    let discovery: KEFDiscovery
    let hardwareButtons: HardwareVolumeButtonController

    private let defaults: UserDefaults
    private let speakerRecords: SpeakerRecordStore
    private let clientFactory: ClientFactory
    private let commands: SpeakerCommandService
    private var currentSpeakerID: String?
    private var volumeTasks: [UUID: Task<Void, Never>] = [:]
    private var lastVolumeTask: Task<Void, Never>?
    private let reconnectPolicy: ReconnectPolicy
    private let pollingInterval: Duration
    private let sleep: Sleep
    private var speaker: KEFSpeakerClient?
    private var speakerMACAddress: String?
    private var connectionTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var commandGeneration = 0
    private var noticeTask: Task<Void, Never>?
    private var appIsActive = false
    private var connectionGeneration = 0
    private var consecutiveFailures = 0
    private var mutedRestoreVolume: Int?
    private var isPreviewingVolume = false
    private let isDemoMode: Bool

    init(
        defaults: UserDefaults = .standard,
        speakerRecords: SpeakerRecordStore? = nil,
        discovery: KEFDiscovery? = nil,
        hardwareButtons: HardwareVolumeButtonController? = nil,
        reconnectPolicy: ReconnectPolicy = ReconnectPolicy(),
        pollingInterval: Duration = .seconds(3),
        sleep: @escaping Sleep = { duration in try await Task.sleep(for: duration) },
        clientFactory: @escaping ClientFactory = { KEFSpeakerAPI(host: $0) }
    ) {
        self.defaults = defaults
        let records = speakerRecords ?? SpeakerRecordStore(defaults: defaults)
        self.speakerRecords = records
        self.commands = SpeakerCommandService(speakerRecords: records, clientFactory: clientFactory)
        self.discovery = discovery ?? KEFDiscovery()
        self.hardwareButtons = hardwareButtons ?? HardwareVolumeButtonController()
        self.reconnectPolicy = reconnectPolicy
        self.pollingInterval = pollingInterval
        self.sleep = sleep
        self.clientFactory = clientFactory

        manualHost = defaults.string(forKey: SpeakerPreferenceKeys.manualHost) ?? ""
        volumeStep = defaults.object(forKey: SpeakerPreferenceKeys.volumeStep) == nil
            ? 5
            : VolumePolicy.clampedStepSize(defaults.integer(forKey: SpeakerPreferenceKeys.volumeStep))
        hardwareButtonsEnabled = defaults.object(forKey: SpeakerPreferenceKeys.hardwareButtonsEnabled) == nil
            ? true
            : defaults.bool(forKey: SpeakerPreferenceKeys.hardwareButtonsEnabled)
        mutePhoneOnExit = defaults.bool(forKey: SpeakerPreferenceKeys.mutePhoneOnExit)

        #if DEBUG
        isDemoMode = ProcessInfo.processInfo.arguments.contains("--demo-mode")
        #else
        isDemoMode = false
        #endif

        self.discovery.localNetworkAccessDeniedHandler = { [weak self] in
            self?.handleLocalNetworkPermissionDenied()
        }
        self.hardwareButtons.onPress = { [weak self] direction in
            self?.adjustVolume(direction: direction.rawValue, originatedFromHardware: true)
        }

        if isDemoMode {
            if ProcessInfo.processInfo.arguments.contains("--demo-error") {
                lastError = "The speaker could not be reached. Check that your iPhone is on the same network, then reconnect to the intended speaker. This detailed message must stay readable at larger accessibility text sizes."
            }
            let demoIsStandby = ProcessInfo.processInfo.arguments.contains("--demo-standby")
            currentHost = "192.168.1.42"
            apply(
                SpeakerSnapshot(
                    status: demoIsStandby ? .standby : .powerOn,
                    source: .wifi,
                    volume: 42,
                    name: "Living Room",
                    model: "LS60"
                )
            )
            connectionState = .connected

            if !demoIsStandby,
               !ProcessInfo.processInfo.arguments.contains("--demo-no-now-playing") {
                isPlaying = !ProcessInfo.processInfo.arguments.contains("--demo-paused")
                nowPlaying = NowPlayingInfo(
                    title: "Night Drive",
                    artist: "The Speakers",
                    album: "Living Room Sessions"
                )
            }
        }
    }

    var hasConfiguredSpeaker: Bool {
        currentHost != nil || savedSpeaker != nil || isDemoMode
    }

    var canControlSpeaker: Bool {
        connectionState == .connected && speakerStatus == .powerOn
    }

    var canControlPlayback: Bool {
        canControlSpeaker && source.usesPlaybackStateForVolumeRouting && nowPlaying != nil
    }

    var isMuted: Bool {
        volume == 0
    }

    var connectionDetail: String {
        switch connectionState {
        case .disconnected:
            "Choose a speaker to begin"
        case .connecting:
            currentHost ?? "Checking your speaker"
        case .connected:
            speakerStatus == .powerOn ? (currentHost ?? "Ready") : speakerStatus.detailText
        case .reconnecting(let attempt):
            "Attempt \(attempt) · \(currentHost ?? "speaker")"
        case .failed(let message):
            message
        }
    }

    func setAppActive(_ isActive: Bool, mutePhoneOnStop: Bool = false) {
        guard appIsActive != isActive else {
            if !isActive, mutePhoneOnStop, mutePhoneOnExit {
                hardwareButtons.stop(mutePhone: true)
            }
            return
        }
        appIsActive = isActive

        if isActive {
            localNetworkPermissionDenied = false
            if isDemoMode {
                updateHardwareButtonCapture()
            } else if let speaker {
                refresh(using: speaker)
                beginPolling(using: speaker)
                updateHardwareButtonCapture()
            } else if let host = currentHost ?? savedSpeaker?.host {
                connect(to: host, macAddress: savedSpeaker?.macAddress, confirmingIdentity: false)
            }
        } else {
            connectionGeneration += 1
            connectionTask?.cancel()
            connectionTask = nil
            pollingTask?.cancel()
            pollingTask = nil
            cancelCommand()
            cancelVolumeTasks()
            isAdjustingVolume = false
            isPreviewingVolume = false
            isSendingCommand = false
            discovery.stopDiscovery()
            hardwareButtons.stop(mutePhone: mutePhoneOnStop && mutePhoneOnExit)
        }
    }

    func startDiscovery() {
        guard appIsActive else { return }
        localNetworkPermissionDenied = false
        lastError = nil
        discovery.startDiscovery()
    }

    func stopDiscovery() {
        discovery.stopDiscovery()
    }

    func connect(to discoveredSpeaker: DiscoveredSpeaker) {
        connect(to: discoveredSpeaker.host, macAddress: discoveredSpeaker.macAddress)
    }

    func connect(to rawHost: String, macAddress: String? = nil, confirmingIdentity: Bool = true) {
        guard let host = ManualHostValidator.normalizedHost(rawHost) else {
            connectionState = .failed(message: "Enter a private IP address or .local hostname.")
            lastError = "That speaker address is not a valid local-network address."
            return
        }

        manualHost = host
        currentHost = host
        defaults.set(host, forKey: SpeakerPreferenceKeys.manualHost)

        guard appIsActive else {
            return
        }

        connectionGeneration += 1
        let generation = connectionGeneration
        connectionTask?.cancel()
        pollingTask?.cancel()
        cancelCommand()
        cancelVolumeTasks()
        isAdjustingVolume = false
        isPreviewingVolume = false
        speaker = nil
        speakerMACAddress = nil
        mutedRestoreVolume = nil
        clearPlayerState()
        hardwareButtons.stop()
        discovery.stopDiscovery()
        consecutiveFailures = 0
        lastError = nil
        connectionState = .connecting
        let candidate = clientFactory(host)
        let savedIdentity = speakerRecords.allSpeakers().first { $0.host == host }
        currentSpeakerID = nil

        connectionTask = Task { @MainActor [weak self, candidate] in
            guard let self else { return }
            do {
                let snapshot = try await candidate.getSnapshot()
                guard !Task.isCancelled,
                      self.appIsActive,
                      self.connectionGeneration == generation else { return }

                if !confirmingIdentity, let savedIdentity, !savedIdentity.accepts(snapshot) {
                    throw SpeakerCommandError.speakerIdentityChanged
                }
                self.speaker = candidate
                self.speakerMACAddress = macAddress
                self.apply(snapshot)
                self.connectionState = .connected
                self.localNetworkPermissionDenied = false
                self.manualHost = host
                self.defaults.set(host, forKey: SpeakerPreferenceKeys.manualHost)
                self.currentSpeakerID = self.speakerRecords.save(
                    host: host,
                    macAddress: macAddress,
                    snapshot: snapshot
                )?.id
                WidgetCenter.shared.reloadTimelines(ofKind: AmpestraWidgetConstants.controlsKind)
                AmpestraShortcuts.updateAppShortcutParameters()
                self.beginPolling(using: candidate)
                self.updateHardwareButtonCapture()
                self.showNotice("Connected to \(snapshot.name)")
                await self.refreshPlayerState(using: candidate, snapshot: snapshot)
            } catch is CancellationError {
                return
            } catch {
                guard self.connectionGeneration == generation else { return }
                self.speaker = nil
                self.connectionState = .failed(message: "Couldn’t reach \(host)")
                self.lastError = self.message(for: error)
                self.updateHardwareButtonCapture()
            }
        }
    }

    func reconnectNow() {
        guard let host = currentHost ?? savedSpeaker?.host else { return }
        connect(
            to: host,
            macAddress: speakerMACAddress ?? savedSpeaker?.macAddress,
            confirmingIdentity: false
        )
    }

    func disconnect(forget: Bool = false) {
        let forgottenID = currentSpeakerID ?? speakerRecords.allSpeakers().first { $0.host == currentHost }?.id
        connectionGeneration += 1
        connectionTask?.cancel()
        pollingTask?.cancel()
        cancelCommand()
        cancelVolumeTasks()
        discovery.stopDiscovery()
        speaker = nil
        speakerMACAddress = nil
        mutedRestoreVolume = nil
        currentHost = nil
        currentSpeakerID = nil
        connectionState = .disconnected
        lastError = nil
        isSendingCommand = false
        isAdjustingVolume = false
        isPreviewingVolume = false
        clearPlayerState()
        hardwareButtons.stop()

        if forget {
            if let forgottenID { speakerRecords.remove(id: forgottenID) }
            manualHost = ""
            defaults.removeObject(forKey: SpeakerPreferenceKeys.manualHost)
            WidgetCenter.shared.reloadTimelines(ofKind: AmpestraWidgetConstants.controlsKind)
            AmpestraShortcuts.updateAppShortcutParameters()
        }
    }

    func refreshNow() {
        if isDemoMode {
            showNotice("Speaker status is up to date")
            return
        }

        guard let speaker else { return }
        refresh(using: speaker)
    }

    func setVolume(_ requestedVolume: Int) {
        isPreviewingVolume = false
        let target = VolumePolicy.clampedVolume(requestedVolume)
        if isDemoMode {
            volume = target
            return
        }

        guard canControlSpeaker, let id = currentSpeakerID else { return }
        volume = target
        enqueueVolumeCommand { [commands] in
            try await commands.setVolume(target, speakerID: id)
        }
    }

    private func enqueueVolumeCommand(
        _ action: @escaping @Sendable () async throws -> SpeakerCommandConfirmation
    ) {
        guard volumeTasks.count < 64 else {
            lastError = message(for: SpeakerCommandError.commandQueueFull)
            return
        }
        let generation = connectionGeneration
        let token = UUID()
        let previous = lastVolumeTask
        isAdjustingVolume = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.volumeTasks[token] = nil
                if self.connectionGeneration == generation {
                    self.isAdjustingVolume = !self.volumeTasks.isEmpty
                    if self.volumeTasks.isEmpty { self.lastVolumeTask = nil }
                }
            }
            do {
                await previous?.value
                try Task.checkCancellation()
                let result = try await action()
                guard !Task.isCancelled, self.connectionGeneration == generation else { return }
                if self.volumeTasks.count == 1 { self.volume = result.volume }
                self.lastError = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.connectionGeneration == generation else { return }
                self.handleCommandFailure(error)
            }
        }
        volumeTasks[token] = task
        lastVolumeTask = task
    }

    private func cancelVolumeTasks() {
        volumeTasks.values.forEach { $0.cancel() }
        volumeTasks.removeAll()
        lastVolumeTask = nil
    }

    func previewVolume(_ requestedVolume: Int) {
        guard canControlSpeaker || isDemoMode else { return }
        isPreviewingVolume = true
        volume = VolumePolicy.clampedVolume(requestedVolume)
    }

    func commitPreviewedVolume() {
        setVolume(volume)
    }

    func adjustVolume(direction: Int, originatedFromHardware: Bool = false) {
        guard direction != 0, canControlSpeaker || isDemoMode else { return }
        let amount = direction.signum() * volumeStep
        let target = VolumePolicy.clampedVolume(volume + amount)
        if isDemoMode { volume = target; return }
        guard let id = currentSpeakerID else { return }
        volume = target
        enqueueVolumeCommand { [commands] in
            try await commands.adjustVolume(by: amount, speakerID: id)
        }
    }

    func toggleMute() {
        guard canControlSpeaker || isDemoMode else { return }
        if isDemoMode {
            let result = VolumePolicy.muteToggle(from: volume, restoreVolume: mutedRestoreVolume)
            mutedRestoreVolume = result.restoreVolume
            volume = result.targetVolume
            return
        }
        guard let id = currentSpeakerID else { return }
        enqueueVolumeCommand { [commands] in
            try await commands.toggleMute(speakerID: id)
        }
    }

    func previousTrack() {
        guard canControlPlayback else { return }
        if isDemoMode {
            showNotice("Skipped back")
            return
        }

        guard let id = currentSpeakerID else { return }
        performCommand(successNotice: "Skipped back") {
            _ = try await self.commands.performPlayback(.previous, speakerID: id)
        }
    }

    func togglePlayPause() {
        guard canControlPlayback else { return }
        let willPlay = !isPlaying
        if isDemoMode {
            isPlaying = willPlay
            showNotice(willPlay ? "Playback resumed" : "Playback paused")
            return
        }

        guard let id = currentSpeakerID else { return }
        performCommand(successNotice: willPlay ? "Playback resumed" : "Playback paused") {
            _ = try await self.commands.performPlayback(willPlay ? .play : .pause, speakerID: id)
        }
    }

    func nextTrack() {
        guard canControlPlayback else { return }
        if isDemoMode {
            showNotice("Skipped forward")
            return
        }

        guard let id = currentSpeakerID else { return }
        performCommand(successNotice: "Skipped forward") {
            _ = try await self.commands.performPlayback(.next, speakerID: id)
        }
    }

    func setSource(_ newSource: SpeakerSource) {
        guard newSource != source else { return }
        if isDemoMode {
            source = newSource
            showNotice("Source changed to \(newSource.displayName)")
            return
        }

        guard canControlSpeaker, let id = currentSpeakerID else { return }
        performCommand(successNotice: "Source changed to \(newSource.displayName)") {
            _ = try await self.commands.setSource(newSource, speakerID: id)
        }
    }

    func togglePower() {
        if isDemoMode {
            speakerStatus = speakerStatus == .powerOn ? .standby : .powerOn
            updateHardwareButtonCapture()
            showNotice(speakerStatus == .powerOn ? "Speaker is awake" : "Speaker is in standby")
            return
        }

        guard connectionState == .connected,
              speakerStatus.allowsPowerToggle,
              let id = currentSpeakerID else { return }
        let shouldPowerOn = speakerStatus == .standby
        performCommand(successNotice: shouldPowerOn ? "Speaker is waking up" : "Speaker is in standby") {
            _ = try await self.commands.setPower(on: shouldPowerOn, speakerID: id)
        }
    }

    func clearError() {
        lastError = nil
        if case .failed = connectionState, speaker == nil {
            connectionState = .disconnected
        }
    }

    func apply(_ snapshot: SpeakerSnapshot) {
        speakerName = snapshot.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "KEF Speaker"
            : snapshot.name
        speakerModel = snapshot.model
        speakerStatus = snapshot.status
        source = snapshot.source
        if !isPreviewingVolume, !isAdjustingVolume {
            volume = VolumePolicy.clampedVolume(snapshot.volume)
            if volume > 0 { mutedRestoreVolume = nil }
        }
        if snapshot.status != .powerOn || !snapshot.source.usesPlaybackStateForVolumeRouting {
            clearPlayerState()
        }
        updateHardwareButtonCapture()
    }

    private var savedSpeaker: SavedSpeaker? {
        speakerRecords.defaultSpeaker()
    }

    private func beginPolling(using speaker: KEFSpeakerClient) {
        pollingTask?.cancel()
        guard appIsActive, !isDemoMode else { return }
        let generation = connectionGeneration

        pollingTask = Task { @MainActor [weak self, weak speaker] in
            guard let self, let speaker else { return }

            while !Task.isCancelled,
                  self.appIsActive,
                  self.connectionGeneration == generation,
                  self.speaker === speaker {
                let delay = self.consecutiveFailures == 0
                    ? self.pollingInterval
                    : self.reconnectPolicy.delay(afterFailure: self.consecutiveFailures)
                do {
                    try await self.sleep(delay)
                    guard !Task.isCancelled, self.connectionGeneration == generation else { return }
                    let snapshot = try await speaker.getSnapshot()
                    guard !Task.isCancelled, self.connectionGeneration == generation,
                          self.speaker === speaker else { return }
                    self.consecutiveFailures = 0
                    self.apply(snapshot)
                    self.connectionState = .connected
                    self.lastError = nil
                    self.updateHardwareButtonCapture()
                    await self.refreshPlayerState(using: speaker, snapshot: snapshot)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, self.connectionGeneration == generation,
                          self.speaker === speaker else { return }
                    self.consecutiveFailures += 1
                    self.connectionState = .reconnecting(attempt: self.consecutiveFailures)
                    self.lastError = self.message(for: error)
                    self.updateHardwareButtonCapture()
                }
            }
        }
    }

    private func refresh(using speaker: KEFSpeakerClient) {
        let generation = connectionGeneration
        Task { @MainActor [weak self, weak speaker] in
            guard let self, let speaker else { return }
            do {
                let snapshot = try await speaker.getSnapshot()
                guard self.connectionGeneration == generation, self.speaker === speaker else { return }
                self.consecutiveFailures = 0
                self.apply(snapshot)
                self.connectionState = .connected
                self.lastError = nil
                await self.refreshPlayerState(using: speaker, snapshot: snapshot)
            } catch is CancellationError {
                return
            } catch {
                guard self.connectionGeneration == generation else { return }
                self.consecutiveFailures += 1
                self.connectionState = .reconnecting(attempt: self.consecutiveFailures)
                self.lastError = self.message(for: error)
                self.updateHardwareButtonCapture()
            }
        }
    }

    private func performCommand(
        successNotice: String,
        action: @escaping @MainActor () async throws -> Void
    ) {
        guard let speaker else { return }
        cancelCommand()
        let generation = connectionGeneration
        let commandID = commandGeneration
        isSendingCommand = true
        commandTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.commandGeneration == commandID {
                    self.isSendingCommand = false
                    self.commandTask = nil
                }
            }

            do {
                try Task.checkCancellation()
                try await action()
                guard !Task.isCancelled, self.connectionGeneration == generation,
                      self.commandGeneration == commandID, self.speaker === speaker else { return }
                self.showNotice(successNotice)
                try await self.sleep(.milliseconds(350))
                try Task.checkCancellation()
                let snapshot = try await speaker.getSnapshot()
                guard !Task.isCancelled, self.connectionGeneration == generation,
                      self.commandGeneration == commandID, self.speaker === speaker else { return }
                self.apply(snapshot)
                self.connectionState = .connected
                self.lastError = nil
                await self.refreshPlayerState(using: speaker, snapshot: snapshot)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.connectionGeneration == generation,
                      self.commandGeneration == commandID, self.speaker === speaker else { return }
                self.handleCommandFailure(error)
            }
        }
    }

    private func cancelCommand() {
        commandGeneration += 1
        commandTask?.cancel()
        commandTask = nil
        isSendingCommand = false
    }

    private func refreshPlayerState(
        using speaker: KEFSpeakerClient,
        snapshot: SpeakerSnapshot
    ) async {
        guard snapshot.status == .powerOn,
              snapshot.source.usesPlaybackStateForVolumeRouting else {
            clearPlayerState()
            return
        }

        let generation = connectionGeneration
        let playerState = try? await speaker.getPlayerState()
        guard !Task.isCancelled, appIsActive, connectionGeneration == generation,
              self.speaker === speaker, speakerStatus == .powerOn,
              source == snapshot.source else { return }

        if let playerState {
            applyPlayerState(playerState)
        } else {
            clearPlayerState()
        }
    }

    private func applyPlayerState(_ playerState: PlayerState) {
        let info = NowPlayingInfo(
            title: normalizedMetadata(playerState.nowPlaying.title),
            artist: normalizedMetadata(playerState.nowPlaying.artist),
            album: normalizedMetadata(playerState.nowPlaying.album)
        )
        isPlaying = playerState.isPlaying
        nowPlaying = info.hasInfo ? info : nil
    }

    private func clearPlayerState() {
        isPlaying = false
        nowPlaying = nil
    }

    private func normalizedMetadata(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func handleCommandFailure(_ error: Error) {
        lastError = message(for: error)
        consecutiveFailures += 1
        connectionState = .reconnecting(attempt: consecutiveFailures)
        updateHardwareButtonCapture()
    }

    func handleLocalNetworkPermissionDenied() {
        localNetworkPermissionDenied = true
        lastError = "Local Network access is off. Allow Ampestra in Settings, then try again."
        if speaker == nil {
            connectionState = .failed(message: "Local Network access is off")
        }
    }

    private func updateHardwareButtonCapture() {
        guard !isDemoMode else {
            hardwareButtons.stop()
            return
        }

        if appIsActive, hardwareButtonsEnabled, canControlSpeaker {
            hardwareButtons.start()
        } else {
            hardwareButtons.stop()
        }
    }

    private func showNotice(_ message: String) {
        noticeTask?.cancel()
        notice = message
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func message(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "Your iPhone is not connected to the speaker’s network."
            case .timedOut:
                return "The speaker did not respond in time."
            case .cannotConnectToHost, .cannotFindHost:
                return "The speaker could not be reached at this address."
            default:
                break
            }
        }

        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }

        return error.localizedDescription
    }
}
