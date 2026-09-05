import AppIntents
import Combine
import Foundation
import KEFCore
import WidgetKit

@MainActor
final class RemoteStore: ObservableObject {
    typealias ClientFactory = @Sendable (String) -> KEFSpeakerClient
    typealias Sleep = @Sendable (Duration) async throws -> Void

    @Published internal(set) var connectionState: SpeakerConnectionState = .disconnected
    @Published internal(set) var currentHost: String?
    @Published private(set) var speakerName = "KEF Speaker"
    @Published private(set) var speakerModel = ""
    @Published internal(set) var speakerStatus: SpeakerStatus = .standby
    @Published internal(set) var source: SpeakerSource = .wifi
    @Published private(set) var volume = 0
    @Published internal(set) var isSendingCommand = false
    @Published internal(set) var isAdjustingVolume = false
    @Published internal(set) var localNetworkPermissionDenied = false
    @Published internal(set) var lastError: String?
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

    let defaults: UserDefaults
    let speakerRecords: SpeakerRecordStore
    let clientFactory: ClientFactory
    private let commands: SpeakerCommandService
    @Published internal(set) var currentSpeakerID: String?
    private var volumeTasks: [UUID: Task<Void, Never>] = [:]
    private var lastVolumeTask: Task<Void, Never>?
    let reconnectPolicy: ReconnectPolicy
    let pollingInterval: Duration
    let sleep: Sleep
    var speaker: KEFSpeakerClient?
    var speakerMACAddress: String?
    var connectionTask: Task<Void, Never>?
    var pollingTask: Task<Void, Never>?
    var refreshTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var commandGeneration = 0
    private var noticeTask: Task<Void, Never>?
    var appIsActive = false
    var connectionGeneration = 0
    var consecutiveFailures = 0
    var mutedRestoreVolume: Int?
    var isPreviewingVolume = false
    let isDemoMode: Bool

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
        #if DEBUG
        let useSavedSpeakerDemo = ProcessInfo.processInfo.arguments.contains("--demo-saved-speakers")
        #else
        let useSavedSpeakerDemo = false
        #endif
        let effectiveDefaults = useSavedSpeakerDemo
            ? UserDefaults(suiteName: "Ampestra.Demo.\(UUID().uuidString)")! : defaults
        self.defaults = effectiveDefaults
        let records = useSavedSpeakerDemo ? SpeakerRecordStore(defaults: effectiveDefaults)
            : (speakerRecords ?? SpeakerRecordStore(defaults: effectiveDefaults))
        self.speakerRecords = records
        self.commands = SpeakerCommandService(speakerRecords: records, clientFactory: clientFactory)
        self.discovery = discovery ?? KEFDiscovery()
        self.hardwareButtons = hardwareButtons ?? HardwareVolumeButtonController()
        self.reconnectPolicy = reconnectPolicy
        self.pollingInterval = pollingInterval
        self.sleep = sleep
        self.clientFactory = clientFactory

        manualHost = effectiveDefaults.string(forKey: SpeakerPreferenceKeys.manualHost) ?? ""
        volumeStep = effectiveDefaults.object(forKey: SpeakerPreferenceKeys.volumeStep) == nil
            ? 5
            : VolumePolicy.clampedStepSize(effectiveDefaults.integer(forKey: SpeakerPreferenceKeys.volumeStep))
        hardwareButtonsEnabled = effectiveDefaults.object(forKey: SpeakerPreferenceKeys.hardwareButtonsEnabled) == nil
            ? true
            : effectiveDefaults.bool(forKey: SpeakerPreferenceKeys.hardwareButtonsEnabled)
        mutePhoneOnExit = effectiveDefaults.bool(forKey: SpeakerPreferenceKeys.mutePhoneOnExit)

        #if DEBUG
        isDemoMode = ProcessInfo.processInfo.arguments.contains("--demo-mode") || useSavedSpeakerDemo
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
            if useSavedSpeakerDemo {
                currentSpeakerID = records.save(
                    host: "192.168.1.42", macAddress: nil,
                    snapshot: SpeakerSnapshot(status: .powerOn, source: .wifi, volume: 42,
                                              name: "Living Room", model: "LS60")
                )?.id
                _ = records.save(
                    host: "192.168.1.43", macAddress: nil,
                    snapshot: SpeakerSnapshot(status: .powerOn, source: .wifi, volume: 25,
                                              name: "Office", model: "LSXII"), makeDefault: false
                )
            }

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

    var savedSpeakers: [SavedSpeaker] { speakerRecords.allSpeakers() }
    var defaultSpeakerID: String? { speakerRecords.defaultSpeaker()?.id }
    var defaultSpeakerName: String { speakerRecords.defaultSpeaker()?.displayName ?? "KEF Speaker" }
    var currentVolumePreferences: SpeakerVolumePreferences {
        currentSpeakerID.map { speakerRecords.volumePreferences(for: $0) } ?? SpeakerVolumePreferences()
    }
    internal(set) var diagnosticHistory = MobileDiagnosticHistory()

    func makeDefaultSpeaker(id: String) {
        guard speakerRecords.setDefaultSpeaker(id: id) else { return }
        objectWillChange.send()
        WidgetCenter.shared.reloadTimelines(ofKind: AmpestraWidgetConstants.controlsKind)
        AmpestraShortcuts.updateAppShortcutParameters()
    }

    func connect(to saved: SavedSpeaker) {
        guard let record = speakerRecords.speaker(id: saved.id) else { return }
        if isDemoMode {
            currentHost = record.host
            currentSpeakerID = record.id
            apply(SpeakerSnapshot(status: .powerOn, source: .wifi,
                                  volume: record.widgetReading?.volume ?? 25,
                                  name: record.name, model: record.model))
            connectionState = .connected
            return
        }
        connect(to: record.host, macAddress: record.macAddress, confirmingIdentity: false,
                expectedSpeakerID: record.id)
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

    func setVolume(_ requestedVolume: Int) {
        isPreviewingVolume = false
        let target = currentVolumePreferences.clampedVolume(requestedVolume)
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

    func cancelVolumeTasks() {
        volumeTasks.values.forEach { $0.cancel() }
        volumeTasks.removeAll()
        lastVolumeTask = nil
    }

    func previewVolume(_ requestedVolume: Int) {
        guard canControlSpeaker || isDemoMode else { return }
        isPreviewingVolume = true
        volume = currentVolumePreferences.clampedVolume(requestedVolume)
    }

    func commitPreviewedVolume() {
        setVolume(volume)
    }

    func adjustVolume(direction: Int, originatedFromHardware: Bool = false) {
        guard direction != 0, canControlSpeaker || isDemoMode else { return }
        let amount = direction.signum() * volumeStep
        let target = currentVolumePreferences.clampedVolume(volume + amount)
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
        if !isDemoMode, !isAdjustingVolume, let id = currentSpeakerID,
           speakerRecords.speaker(id: id)?.accepts(snapshot) == true {
            speakerRecords.updateWidgetReading(
                id: id, volume: snapshot.volume, isPoweredOn: snapshot.status == .powerOn
            )
        }
        updateIfChanged(\.speakerName, snapshot.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "KEF Speaker"
            : snapshot.name)
        updateIfChanged(\.speakerModel, snapshot.model)
        updateIfChanged(\.speakerStatus, snapshot.status)
        updateIfChanged(\.source, snapshot.source)
        if !isPreviewingVolume, !isAdjustingVolume {
            updateIfChanged(\.volume, VolumePolicy.clampedVolume(snapshot.volume))
            if volume > 0 { mutedRestoreVolume = nil }
        }
        if snapshot.status != .powerOn || !snapshot.source.usesPlaybackStateForVolumeRouting {
            clearPlayerState()
        }
        updateHardwareButtonCapture()
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

    func cancelCommand() {
        commandGeneration += 1
        commandTask?.cancel()
        commandTask = nil
        isSendingCommand = false
    }

    func applyPlayerState(_ playerState: PlayerState) {
        let info = NowPlayingInfo(
            title: normalizedMetadata(playerState.nowPlaying.title),
            artist: normalizedMetadata(playerState.nowPlaying.artist),
            album: normalizedMetadata(playerState.nowPlaying.album)
        )
        updateIfChanged(\.isPlaying, playerState.isPlaying)
        updateIfChanged(\.nowPlaying, info.hasInfo ? info : nil)
    }

    func clearPlayerState() {
        updateIfChanged(\.isPlaying, false)
        updateIfChanged(\.nowPlaying, nil)
    }

    func updateIfChanged<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<RemoteStore, Value>, _ value: Value
    ) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
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
        diagnosticHistory.record(.localNetworkPermission)
        lastError = "Local Network access is off. Allow Ampestra in Settings, then try again."
        if speaker == nil {
            connectionState = .failed(message: "Local Network access is off")
        }
    }

    func updateHardwareButtonCapture() {
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

    func showNotice(_ message: String) {
        noticeTask?.cancel()
        notice = message
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func message(for error: Error) -> String {
        diagnosticHistory.record(.classify(error))
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
