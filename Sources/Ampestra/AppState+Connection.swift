import Foundation
import KEFCore

/// Connection lifecycle, trusted discovery, health recovery, and snapshot polling.
/// Action execution and optimistic volume reconciliation remain on AppState.
@MainActor
extension AppState {
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
        connectionSession.connectionTask = Task { @MainActor in
            var attemptedHosts = Set<String>()
            let trustedLastConnectedHost = trustedHostForAutoConnection(lastConnectedHost)
            var nextTrustedHostAttempt: ContinuousClock.Instant?

            if let trustedLastConnectedHost {
                attemptedHosts.insert(trustedLastConnectedHost)
                if await establishConnection(to: trustedLastConnectedHost, retryCount: 2, trustOnSuccess: true) {
                    return
                }
                nextTrustedHostAttempt = ContinuousClock.now + timing.reconnectRetryDelay
            }

            let deadline = ContinuousClock.now + timing.autoDiscoveryTimeout
            while ContinuousClock.now < deadline {
                guard !Task.isCancelled else { return }

                if let trustedLastConnectedHost,
                   let scheduledAttempt = nextTrustedHostAttempt,
                   ContinuousClock.now >= scheduledAttempt {
                    if await establishConnection(
                        to: trustedLastConnectedHost,
                        retryCount: 1,
                        trustOnSuccess: true
                    ) {
                        return
                    }
                    nextTrustedHostAttempt = ContinuousClock.now + timing.reconnectRetryDelay
                }

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
                if !needsLocalNetworkAccess {
                    updateIfChanged(\.connectionError, discovery.speakers.isEmpty
                        ? "No KEF speaker found"
                        : "Choose a discovered speaker to connect")
                }
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

        connectionSession.connectionTask = Task { @MainActor in
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
        connectionSession.connectionTask?.cancel()
        connectionSession.connectionTask = nil
        discovery.stopDiscovery()
        connectionSession.pollingController.stop()
        connectionSession.needsTrailingRefresh = false
        connectionSession.lastPlaybackStateRefresh = nil
        speaker = nil
        updateIfChanged(\.isConnected, false)
        updateIfChanged(\.isReconnecting, false)
        updateIfChanged(\.needsLocalNetworkAccess, false)
        updateIfChanged(\.currentHost, nil)
        updateIfChanged(\.connectionError, nil)
        connectionSession.consecutiveRefreshFailures = 0
        resetSpeakerActionState()
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
                guard !Task.isCancelled, self.speaker === api else { return false }
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

    func handleLocalNetworkAccessDenied() {
        updateIfChanged(\.needsLocalNetworkAccess, true)
        updateIfChanged(
            \.connectionError,
            "macOS reports that Local Network access is blocked, even though System Settings may show it as enabled."
        )
    }

    // MARK: - Polling

    private func startPolling() {
        connectionSession.pollingController.start(
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
            connectionSession.lastPlaybackStateRefresh = ContinuousClock.now
        } catch {
            guard self.speaker === speaker else { return }
        }
    }

    func refresh() async {
        if connectionSession.isRefreshInProgress {
            connectionSession.needsTrailingRefresh = true
            return
        }

        connectionSession.isRefreshInProgress = true
        defer { connectionSession.isRefreshInProgress = false }

        repeat {
            connectionSession.needsTrailingRefresh = false
            await performRefresh()
        } while connectionSession.needsTrailingRefresh
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
                    connectionSession.lastPlaybackStateRefresh = ContinuousClock.now
                } else {
                    clearPlayerState()
                }
            } else if snapshot.status != .powerOn || !snapshot.source.usesPlaybackStateForVolumeRouting {
                clearPlayerState()
                connectionSession.lastPlaybackStateRefresh = nil
            }

            markConnectionHealthy(for: speaker)
            clearRecoveredNetworkActionError()
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
        guard isPlaybackStatePollingNeeded, let lastPlaybackStateRefresh = connectionSession.lastPlaybackStateRefresh else {
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

    func markConnectionHealthy(
        for speaker: KEFSpeakerClient,
        stopDiscovery: Bool = false,
        trustHost: Bool = false
    ) {
        guard self.speaker === speaker else { return }

        connectionSession.consecutiveRefreshFailures = 0
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

    func recordConnectionFailure(for speaker: KEFSpeakerClient) {
        guard self.speaker === speaker else { return }

        connectionSession.consecutiveRefreshFailures += 1

        if connectionSession.consecutiveRefreshFailures >= 3 || !isConnected {
            updateIfChanged(\.isConnected, false)
            updateIfChanged(\.isReconnecting, true)
            updateIfChanged(\.connectionError, "Reconnecting to speaker...")
        }
    }

    // MARK: - Wake-on-LAN

    var speakerMAC: String? {
        guard let host = currentHost ?? preferredWakeHost else { return nil }
        return discovery.speakers.first(where: { $0.host == host })?.macAddress
    }

    var preferredWakeHost: String? {
        if let trustedLastConnectedHost = trustedHostForAutoConnection(lastConnectedHost) {
            return trustedLastConnectedHost
        }

        return discovery.speakers
            .compactMap { trustedHostForAutoConnection($0.host) }
            .first
    }}
