import AppIntents
import Foundation
import KEFCore
import WidgetKit

/// Connection, foreground recovery, and polling share one generation to reject stale results.
/// All operations remain main-actor isolated with RemoteStore.
extension RemoteStore {
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
            } else if currentHost != nil || savedSpeaker != nil {
                reconnectNow()
            }
        } else {
            connectionGeneration += 1
            connectionTask?.cancel()
            connectionTask = nil
            pollingTask?.cancel()
            pollingTask = nil
            cancelRefresh()
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
        guard appIsActive, !isDemoMode else { return }
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

    func connect(to rawHost: String, macAddress: String? = nil, confirmingIdentity: Bool = true, expectedSpeakerID: String? = nil) {
        guard let host = ManualHostValidator.normalizedHost(rawHost) else {
            diagnosticHistory.record(.invalidAddress)
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
        cancelRefresh()
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
        let savedIdentity = expectedSpeakerID.flatMap { speakerRecords.speaker(id: $0) }
            ?? speakerRecords.allSpeakers().first { $0.host == host }
        currentSpeakerID = savedIdentity?.id

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
                    snapshot: snapshot,
                    makeDefault: false
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
        let record = currentSpeakerID.flatMap { speakerRecords.speaker(id: $0) }
            ?? (currentHost == nil ? savedSpeaker : speakerRecords.allSpeakers().first { $0.host == currentHost })
        guard let host = currentHost ?? record?.host else { return }
        connect(
            to: host,
            macAddress: speakerMACAddress ?? record?.macAddress,
            confirmingIdentity: false,
            expectedSpeakerID: record?.id
        )
    }

    func disconnect(forget: Bool = false) {
        let forgottenID = currentSpeakerID ?? speakerRecords.allSpeakers().first { $0.host == currentHost }?.id
        connectionGeneration += 1
        connectionTask?.cancel()
        pollingTask?.cancel()
        cancelRefresh()
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

    /// The foreground remote restores its last selection independently of Siri’s default.
    var savedSpeaker: SavedSpeaker? {
        if let host = ManualHostValidator.normalizedHost(manualHost),
           let selected = speakerRecords.allSpeakers().first(where: {
               $0.host == host && $0.requiresReconfirmation != true && !$0.model.isEmpty
           }) {
            return selected
        }
        return speakerRecords.defaultSpeaker()
    }

    func beginPolling(using speaker: KEFSpeakerClient) {
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
                } catch {
                    return
                }
                await self.refresh(using: speaker).value
            }
        }
    }

    /// Manual refreshes and polling share the same request, including player metadata.
    @discardableResult
    func refresh(using speaker: KEFSpeakerClient) -> Task<Void, Never> {
        if let refreshTask { return refreshTask }
        let generation = connectionGeneration
        let task = Task { @MainActor [weak self, weak speaker] in
            guard let self, let speaker else { return }
            defer {
                if self.connectionGeneration == generation {
                    self.refreshTask = nil
                }
            }
            guard !Task.isCancelled, self.appIsActive,
                  self.connectionGeneration == generation, self.speaker === speaker else { return }
            do {
                let snapshot = try await speaker.getSnapshot()
                guard !Task.isCancelled, self.connectionGeneration == generation,
                      self.speaker === speaker else { return }
                self.consecutiveFailures = 0
                self.updateIfChanged(\.connectionState, .connected)
                self.updateIfChanged(\.lastError, nil)
                self.apply(snapshot)
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
        refreshTask = task
        return task
    }

    func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refreshPlayerState(
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

}
