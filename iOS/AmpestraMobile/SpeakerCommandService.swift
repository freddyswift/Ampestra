import Foundation
import KEFCore
import OSLog

struct SpeakerCommandTimingPolicy: Sendable {
    var commandTimeout: Duration = .seconds(25)
    var readAttempts = 2
    var readRetryDelay: Duration = .milliseconds(250)
    var wakePollingDelays: [Duration] = [
        .milliseconds(350),
        .milliseconds(700),
        .seconds(1),
        .seconds(2),
    ]
}

actor SpeakerCommandService {
    typealias ClientFactory = @Sendable (String) -> KEFSpeakerClient
    typealias Sleep = @Sendable (Duration) async throws -> Void
    typealias WakeSender = @Sendable (String) -> Bool

    private static let logger = Logger(
        subsystem: "com.freddyswift.ampestra",
        category: "SpeakerCommands"
    )

    private let speakerRecords: SpeakerRecordStore
    private let clientFactory: ClientFactory
    private let timing: SpeakerCommandTimingPolicy
    private let sleep: Sleep
    private let wakeSender: WakeSender

    init(
        defaults: UserDefaults = .standard,
        clientFactory: @escaping ClientFactory = { KEFSpeakerAPI(host: $0) },
        timing: SpeakerCommandTimingPolicy = SpeakerCommandTimingPolicy(),
        sleep: @escaping Sleep = { duration in try await Task.sleep(for: duration) },
        wakeSender: @escaping WakeSender = { sendWakeOnLAN(macAddress: $0) }
    ) {
        speakerRecords = SpeakerRecordStore(defaults: defaults)
        self.clientFactory = clientFactory
        self.timing = timing
        self.sleep = sleep
        self.wakeSender = wakeSender
    }

    init(
        speakerRecords: SpeakerRecordStore,
        clientFactory: @escaping ClientFactory = { KEFSpeakerAPI(host: $0) },
        timing: SpeakerCommandTimingPolicy = SpeakerCommandTimingPolicy(),
        sleep: @escaping Sleep = { duration in try await Task.sleep(for: duration) },
        wakeSender: @escaping WakeSender = { sendWakeOnLAN(macAddress: $0) }
    ) {
        self.speakerRecords = speakerRecords
        self.clientFactory = clientFactory
        self.timing = timing
        self.sleep = sleep
        self.wakeSender = wakeSender
    }

    private let commandQueue = SpeakerCommandQueue.shared

    func status(speakerID: String? = nil) async throws -> SpeakerCommandConfirmation {
        try await execute(.status, speakerID: speakerID)
    }

    func setSource(_ source: SpeakerSource, speakerID: String? = nil) async throws -> SpeakerCommandConfirmation {
        try await execute(.source(source), speakerID: speakerID)
    }

    func adjustVolume(by amount: Int, speakerID: String? = nil) async throws -> SpeakerCommandConfirmation {
        try await execute(.adjust(amount), speakerID: speakerID)
    }

    func setVolume(_ volume: Int, speakerID: String? = nil) async throws -> SpeakerCommandConfirmation {
        try await execute(.volume(volume), speakerID: speakerID)
    }

    func setMuted(_ muted: Bool, speakerID: String? = nil) async throws -> SpeakerCommandConfirmation {
        try await execute(.mute(muted), speakerID: speakerID)
    }

    func toggleMute(speakerID: String? = nil) async throws -> SpeakerCommandConfirmation {
        try await execute(.toggleMute, speakerID: speakerID)
    }

    func setPower(on: Bool, speakerID: String? = nil) async throws -> SpeakerCommandConfirmation {
        try await execute(.power(on), speakerID: speakerID)
    }

    func performPlayback(_ action: SpeakerPlaybackCommand, speakerID: String? = nil) async throws -> SpeakerCommandConfirmation {
        try await execute(.playback(action), speakerID: speakerID)
    }

    private func execute(_ command: Command, speakerID: String?) async throws -> SpeakerCommandConfirmation {
        let id = try configuredSpeaker(id: speakerID).id
        let timeout = timing.commandTimeout
        return try await withThrowingTaskGroup(of: SpeakerCommandConfirmation.self) { group in
            group.addTask {
                try await self.commandQueue.run(speakerID: id) {
                    try await self.perform(command, speakerID: id)
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SpeakerCommandError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    private enum Command: Sendable {
        case status, source(SpeakerSource), adjust(Int), volume(Int), mute(Bool), toggleMute
        case power(Bool), playback(SpeakerPlaybackCommand)
    }

    private func perform(_ command: Command, speakerID: String) async throws -> SpeakerCommandConfirmation {
        // Resolve again after acquiring the queue: a queued command must not
        // resurrect a speaker that was forgotten while it waited.
        _ = try configuredSpeaker(id: speakerID)
        let result: SpeakerCommandConfirmation
        switch command {
        case .status: result = try await performStatus(speakerID: speakerID)
        case .source(let source): result = try await performSetSource(source, speakerID: speakerID)
        case .adjust(let amount): result = try await performAdjustVolume(by: amount, speakerID: speakerID)
        case .volume(let volume): result = try await performSetVolume(volume, speakerID: speakerID)
        case .mute(let muted): result = try await performSetMuted(muted, speakerID: speakerID)
        case .toggleMute:
            let connection = try await connection(for: speakerID)
            result = try await performSetMuted(connection.snapshot.volume > 0, speakerID: speakerID, connection: connection)
        case .power(let on): result = try await performSetPower(on: on, speakerID: speakerID)
        case .playback(let action): result = try await performPlaybackCommand(action, speakerID: speakerID)
        }
        switch command {
        case .adjust, .volume, .mute, .toggleMute:
            await commandQueue.rememberVolume(result.volume, speakerID: speakerID)
        case .source, .power:
            await commandQueue.clearVolume(speakerID: speakerID)
        default: break
        }
        speakerRecords.updateWidgetReading(
            id: result.speakerID, volume: result.volume, isPoweredOn: result.status == .powerOn
        )
        return result
    }

    private func performStatus(speakerID: String? = nil) async throws -> SpeakerCommandConfirmation {
        let connection = try await connection(for: speakerID)
        return confirmation(
            record: connection.record,
            snapshot: connection.snapshot,
            changed: false,
            message: statusMessage(name: speakerName(from: connection.snapshot), snapshot: connection.snapshot)
        )
    }

    private func performSetSource(
        _ source: SpeakerSource,
        speakerID: String? = nil
    ) async throws -> SpeakerCommandConfirmation {
        let connection = try await connection(for: speakerID)
        try requirePoweredOn(connection.snapshot)

        let changed = connection.snapshot.source != source
        if changed {
            try await performWrite(command: "set-source", connection: connection) {
                try await connection.client.setSource(source)
            }
        }

        var snapshot = connection.snapshot
        snapshot.source = source
        let name = speakerName(from: snapshot)
        return confirmation(
            record: connection.record,
            snapshot: snapshot,
            changed: changed,
            message: "\(name) is set to \(source.displayName)."
        )
    }

    func adjustVolume(
        direction: Int,
        speakerID: String? = nil
    ) async throws -> SpeakerCommandConfirmation {
        guard direction != 0 else { throw SpeakerCommandError.invalidAdjustment }
        let amount = direction > 0
            ? speakerRecords.preferredVolumeStep()
            : -speakerRecords.preferredVolumeStep()
        return try await adjustVolume(by: amount, speakerID: speakerID)
    }

    private func performAdjustVolume(
        by amount: Int,
        speakerID: String? = nil
    ) async throws -> SpeakerCommandConfirmation {
        guard amount != 0 else { throw SpeakerCommandError.invalidAdjustment }
        let connection = try await connection(for: speakerID)
        try requirePoweredOn(connection.snapshot)

        let current = VolumePolicy.clampedVolume(connection.snapshot.volume)
        let boundedAmount = min(100, max(-100, amount))
        let target = speakerRecords.volumePreferences(for: connection.record.id).clampedVolume(current + boundedAmount)
        let changed = target != connection.snapshot.volume
        if changed {
            try await performWrite(command: "adjust-volume", connection: connection) {
                try await connection.client.setVolume(target)
            }
        }
        if target > 0 {
            speakerRecords.rememberAudibleVolume(target, for: connection.record.id)
        }

        var snapshot = connection.snapshot
        snapshot.volume = target
        let name = speakerName(from: snapshot)
        return confirmation(
            record: connection.record,
            snapshot: snapshot,
            changed: changed,
            message: "\(name) volume is \(target)."
        )
    }

    private func performSetVolume(
        _ volume: Int,
        speakerID: String? = nil
    ) async throws -> SpeakerCommandConfirmation {
        guard 0...100 ~= volume else { throw SpeakerCommandError.invalidVolume }
        let connection = try await connection(for: speakerID)
        try requirePoweredOn(connection.snapshot)

        let volume = speakerRecords.volumePreferences(for: connection.record.id).clampedVolume(volume)
        let changed = connection.snapshot.volume != volume
        if changed {
            try await performWrite(command: "set-volume", connection: connection) {
                try await connection.client.setVolume(volume)
            }
        }
        if volume > 0 {
            speakerRecords.rememberAudibleVolume(volume, for: connection.record.id)
        }

        var snapshot = connection.snapshot
        snapshot.volume = volume
        let name = speakerName(from: snapshot)
        return confirmation(
            record: connection.record,
            snapshot: snapshot,
            changed: changed,
            message: "\(name) volume is \(volume)."
        )
    }

    private func performSetMuted(
        _ shouldMute: Bool,
        speakerID: String? = nil,
        connection suppliedConnection: SpeakerConnection? = nil
    ) async throws -> SpeakerCommandConfirmation {
        let connection: SpeakerConnection
        if let suppliedConnection { connection = suppliedConnection }
        else { connection = try await self.connection(for: speakerID) }
        try requirePoweredOn(connection.snapshot)

        if shouldMute, connection.snapshot.volume > 0 {
            speakerRecords.rememberAudibleVolume(connection.snapshot.volume, for: connection.record.id)
        }
        let requestedTarget = shouldMute ? 0 : (connection.snapshot.volume > 0
            ? connection.snapshot.volume : (connection.record.lastAudibleVolume ?? 20))
        let target = speakerRecords.volumePreferences(for: connection.record.id).clampedVolume(requestedTarget)
        let changed = connection.snapshot.volume != target
        if changed {
            try await performWrite(command: shouldMute ? "mute" : "unmute", connection: connection) {
                try await connection.client.setVolume(target)
            }
        }
        if target > 0 {
            speakerRecords.rememberAudibleVolume(target, for: connection.record.id)
        }

        var snapshot = connection.snapshot
        snapshot.volume = target
        let name = speakerName(from: snapshot)
        let message: LocalizedStringResource = shouldMute
            ? "\(name) is muted."
            : "\(name) is unmuted at \(target)."
        return confirmation(
            record: connection.record,
            snapshot: snapshot,
            changed: changed,
            message: message
        )
    }

    private func performSetPower(
        on shouldPowerOn: Bool,
        speakerID: String? = nil
    ) async throws -> SpeakerCommandConfirmation {
        let record = try configuredSpeaker(id: speakerID)

        do {
            let connection = try await connection(to: record, retryReads: !shouldPowerOn)
            guard connection.snapshot.status.allowsPowerToggle else {
                throw SpeakerCommandError.powerUnavailable
            }
            let isPoweredOn = connection.snapshot.status == .powerOn
            let changed = shouldPowerOn != isPoweredOn

            if changed {
                try await performWrite(
                    command: shouldPowerOn ? "power-on" : "standby",
                    connection: connection
                ) {
                    if shouldPowerOn {
                        try await connection.client.powerOn()
                    } else {
                        try await connection.client.shutdown()
                    }
                }
            }

            var snapshot = connection.snapshot
            snapshot.status = shouldPowerOn ? .powerOn : .standby
            return powerConfirmation(record: connection.record, snapshot: snapshot, changed: changed)
        } catch let error as SpeakerCommandError where shouldPowerOn && error.isReachabilityFailure {
            return try await wake(record)
        }
    }

    private func performPlaybackCommand(
        _ action: SpeakerPlaybackCommand,
        speakerID: String? = nil
    ) async throws -> SpeakerCommandConfirmation {
        let connection = try await connection(for: speakerID)
        try requirePoweredOn(connection.snapshot)
        guard connection.snapshot.source.usesPlaybackStateForVolumeRouting else {
            throw SpeakerCommandError.playbackUnavailable
        }

        let playerState: PlayerState
        do {
            playerState = try await connection.client.getPlayerState()
        } catch {
            throw mappedError(error)
        }

        var isPlaying = playerState.isPlaying
        let changed: Bool
        switch action {
        case .play:
            changed = !isPlaying
            if changed {
                try await performWrite(command: "play", connection: connection) {
                    try await connection.client.togglePlayPause()
                }
                isPlaying = true
            }
        case .pause:
            changed = isPlaying
            if changed {
                try await performWrite(command: "pause", connection: connection) {
                    try await connection.client.togglePlayPause()
                }
                isPlaying = false
            }
        case .next:
            changed = true
            try await performWrite(command: "next", connection: connection) {
                try await connection.client.nextTrack()
            }
        case .previous:
            changed = true
            try await performWrite(command: "previous", connection: connection) {
                try await connection.client.previousTrack()
            }
        }

        let name = speakerName(from: connection.snapshot)
        let message: LocalizedStringResource
        switch action {
        case .play:
            message = "Playback resumed on \(name)."
        case .pause:
            message = "Playback paused on \(name)."
        case .next:
            message = "Skipped forward on \(name)."
        case .previous:
            message = "Skipped back on \(name)."
        }

        var result = confirmation(
            record: connection.record,
            snapshot: connection.snapshot,
            changed: changed,
            message: message
        )
        result.isPlaying = isPlaying
        return result
    }

    private func configuredSpeaker(id: String?) throws -> SavedSpeaker {
        if let id {
            guard let speaker = speakerRecords.speaker(id: id) else {
                throw SpeakerCommandError.speakerNotFound
            }
            return speaker
        }

        guard let speaker = speakerRecords.defaultSpeaker() else {
            throw SpeakerCommandError.noConfiguredSpeaker
        }
        return speaker
    }

    private func connection(for speakerID: String?) async throws -> SpeakerConnection {
        try await connection(to: configuredSpeaker(id: speakerID), retryReads: true)
    }

    private func connection(
        to record: SavedSpeaker,
        retryReads: Bool
    ) async throws -> SpeakerConnection {
        guard record.requiresReconfirmation != true else { throw SpeakerCommandError.speakerIdentityChanged }
        var lastError: SpeakerCommandError = .unreachable

        for (hostIndex, host) in record.connectionHosts.enumerated() {
            try Task.checkCancellation()
            let client = clientFactory(host)
            do {
                var snapshot = try await readSnapshot(from: client, retry: retryReads)
                guard record.accepts(snapshot) else { throw SpeakerCommandError.speakerIdentityChanged }
                snapshot.volume = await commandQueue.reconciledVolume(snapshot.volume, speakerID: record.id)
                speakerRecords.markReachable(id: record.id, host: host, snapshot: snapshot)
                let updatedRecord = speakerRecords.speaker(id: record.id) ?? record
                return SpeakerConnection(
                    record: updatedRecord,
                    host: host,
                    client: client,
                    snapshot: snapshot
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                lastError = mappedError(error)
                Self.logger.debug(
                    "Speaker connection candidate \(hostIndex + 1, privacy: .public) failed for \(record.id, privacy: .private(mask: .hash)): \(String(describing: lastError), privacy: .private)"
                )
            }
        }

        throw lastError
    }

    private func readSnapshot(
        from client: KEFSpeakerClient,
        retry: Bool
    ) async throws -> SpeakerSnapshot {
        let attempts = retry ? max(1, timing.readAttempts) : 1
        var lastError: Error = SpeakerCommandError.unreachable

        for attempt in 0..<attempts {
            try Task.checkCancellation()
            do {
                let snapshot = try await client.getSnapshot()
                try Task.checkCancellation()
                return snapshot
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                lastError = error
                let mapped = mappedError(error)
                guard attempt + 1 < attempts, mapped.isReachabilityFailure else { break }
                Self.logger.debug(
                    "Retrying speaker snapshot read after attempt \(attempt + 1, privacy: .public)"
                )
                try await sleep(timing.readRetryDelay)
            }
        }

        throw mappedError(lastError)
    }

    private func wake(_ record: SavedSpeaker) async throws -> SpeakerCommandConfirmation {
        try Task.checkCancellation()
        guard let macAddress = record.macAddress else {
            throw SpeakerCommandError.wakeUnavailable
        }
        guard wakeSender(macAddress) else {
            throw SpeakerCommandError.wakeFailed
        }
        Self.logger.info(
            "Wake-on-LAN sent for \(record.id, privacy: .private(mask: .hash))"
        )

        var lastError: SpeakerCommandError = .wakeTimedOut
        for delay in timing.wakePollingDelays {
            try await sleep(delay)

            do {
                let connection = try await connection(to: record, retryReads: false)
                var snapshot = connection.snapshot
                guard snapshot.status.allowsPowerToggle else {
                    throw SpeakerCommandError.powerUnavailable
                }
                if snapshot.status != .powerOn {
                    try await performWrite(command: "power-on-after-wake", connection: connection) {
                        try await connection.client.powerOn()
                    }
                    snapshot.status = .powerOn
                }
                return powerConfirmation(record: connection.record, snapshot: snapshot, changed: true)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = mappedError(error)
            }
        }

        if lastError.isReachabilityFailure {
            throw SpeakerCommandError.wakeTimedOut
        }
        throw lastError
    }

    private func performWrite(
        command: String,
        connection: SpeakerConnection,
        operation: () async throws -> Void
    ) async throws {
        let speakerID = connection.record.id
        let clock = ContinuousClock()
        let start = clock.now

        do {
            try Task.checkCancellation()
            guard let record = speakerRecords.speaker(id: speakerID) else {
                throw SpeakerCommandError.speakerNotFound
            }
            guard record.host == connection.host,
                  record.macAddress == connection.record.macAddress,
                  record.accepts(connection.snapshot) else {
                throw SpeakerCommandError.speakerIdentityChanged
            }
            try await operation()
            try Task.checkCancellation()
            let milliseconds = Self.milliseconds(start.duration(to: clock.now))
            Self.logger.info(
                "Speaker command \(command, privacy: .public) succeeded in \(milliseconds, privacy: .public) ms for \(speakerID, privacy: .private(mask: .hash))"
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            let mapped = mappedError(error)
            let milliseconds = Self.milliseconds(start.duration(to: clock.now))
            Self.logger.error(
                "Speaker command \(command, privacy: .public) failed in \(milliseconds, privacy: .public) ms for \(speakerID, privacy: .private(mask: .hash)): \(String(describing: mapped), privacy: .private)"
            )
            throw mapped
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
    }

    private func powerConfirmation(
        record: SavedSpeaker,
        snapshot: SpeakerSnapshot,
        changed: Bool
    ) -> SpeakerCommandConfirmation {
        let name = speakerName(from: snapshot)
        let isPoweredOn = snapshot.status == .powerOn
        let message: LocalizedStringResource = isPoweredOn
            ? "\(name) is on."
            : "\(name) is in standby."
        return confirmation(record: record, snapshot: snapshot, changed: changed, message: message)
    }

    private func confirmation(
        record: SavedSpeaker,
        snapshot: SpeakerSnapshot,
        changed: Bool,
        message: LocalizedStringResource
    ) -> SpeakerCommandConfirmation {
        SpeakerCommandConfirmation(
            speakerID: record.id,
            speakerName: speakerName(from: snapshot),
            status: snapshot.status,
            source: snapshot.source,
            volume: VolumePolicy.clampedVolume(snapshot.volume),
            isPlaying: nil,
            changed: changed,
            message: message
        )
    }

    private func statusMessage(
        name: String,
        snapshot: SpeakerSnapshot
    ) -> LocalizedStringResource {
        if snapshot.status == .powerOn {
            return "\(name) is on, set to \(snapshot.source.displayName), at volume \(snapshot.volume)."
        }
        return "\(name) is \(snapshot.status.displayName.lowercased())."
    }

    private func requirePoweredOn(_ snapshot: SpeakerSnapshot) throws {
        guard snapshot.status == .powerOn else {
            throw SpeakerCommandError.speakerInStandby
        }
    }

    private func speakerName(from snapshot: SpeakerSnapshot) -> String {
        let name = snapshot.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Your speaker" : name
    }

    private func mappedError(_ error: Error) -> SpeakerCommandError {
        if let commandError = error as? SpeakerCommandError {
            return commandError
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return .notOnSpeakerNetwork
            case .timedOut:
                return .timedOut
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return .unreachable
            default:
                return .unreachable
            }
        }

        if let kefError = error as? KEFError {
            switch kefError {
            case .invalidResponse:
                return .invalidResponse
            case .connectionFailed:
                return .unreachable
            case .apiError(let message):
                return .commandRejected(message)
            }
        }

        return .unreachable
    }
}

enum SpeakerPlaybackCommand: String, Equatable, Sendable {
    case play
    case pause
    case next
    case previous
}

struct SpeakerCommandConfirmation: Equatable, Sendable {
    let speakerID: String
    let speakerName: String
    let status: SpeakerStatus
    let source: SpeakerSource
    let volume: Int
    var isPlaying: Bool?
    let changed: Bool
    let message: LocalizedStringResource
}

enum SpeakerCommandError: Error, Equatable, Sendable, LocalizedError, CustomLocalizedStringResourceConvertible {
    case noConfiguredSpeaker
    case commandQueueFull
    case speakerIdentityChanged
    case speakerNotFound
    case speakerInStandby
    case powerUnavailable
    case invalidVolume
    case invalidAdjustment
    case playbackUnavailable
    case notOnSpeakerNetwork
    case timedOut
    case unreachable
    case invalidResponse
    case commandRejected(String)
    case wakeUnavailable
    case wakeFailed
    case wakeTimedOut

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noConfiguredSpeaker:
            "Open Ampestra and connect a speaker first."
        case .commandQueueFull:
            "Too many speaker commands are waiting. Try again in a moment."
        case .speakerIdentityChanged:
            "The saved speaker address or identity has changed. Open Ampestra and reconnect the intended speaker."
        case .speakerNotFound:
            "That saved speaker is no longer available in Ampestra."
        case .speakerInStandby:
            "Your speaker is in standby. Ask me to turn it on first."
        case .powerUnavailable:
            "Power controls are unavailable while your speaker is updating, being set up, or reporting an unknown state."
        case .invalidVolume:
            "Choose a speaker volume between 0 and 100."
        case .invalidAdjustment:
            "Choose whether to turn the speaker volume up or down."
        case .playbackUnavailable:
            "Playback controls are available only for Wi‑Fi or Bluetooth playback."
        case .notOnSpeakerNetwork:
            "Your iPhone isn't connected to the speaker's network."
        case .timedOut:
            "Your speaker didn't respond in time."
        case .unreachable:
            "I couldn't reach your speaker. Make sure it is on the same network as your iPhone."
        case .invalidResponse:
            "Your speaker returned a response Ampestra couldn't understand."
        case .commandRejected(let message):
            "Your speaker rejected the command: \(message)"
        case .wakeUnavailable:
            "I couldn't wake your speaker because Ampestra doesn't have its hardware address."
        case .wakeFailed:
            "Ampestra couldn't send the wake request on your local network."
        case .wakeTimedOut:
            "The wake request was sent, but your speaker didn't come online in time."
        }
    }

    var errorDescription: String? {
        String(localized: localizedStringResource)
    }

    var isReachabilityFailure: Bool {
        switch self {
        case .notOnSpeakerNetwork, .timedOut, .unreachable:
            true
        default:
            false
        }
    }
}

private struct SpeakerConnection {
    let record: SavedSpeaker
    let host: String
    let client: KEFSpeakerClient
    let snapshot: SpeakerSnapshot
}
