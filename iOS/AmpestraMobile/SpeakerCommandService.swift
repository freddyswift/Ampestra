import Foundation
import KEFCore
import OSLog

struct SpeakerCommandTimingPolicy: Sendable {
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

    func status(speakerID: String? = nil) async throws -> SpeakerCommandConfirmation {
        let connection = try await connection(for: speakerID)
        return confirmation(
            record: connection.record,
            snapshot: connection.snapshot,
            changed: false,
            message: statusMessage(name: speakerName(from: connection.snapshot), snapshot: connection.snapshot)
        )
    }

    func setSource(
        _ source: SpeakerSource,
        speakerID: String? = nil
    ) async throws -> SpeakerCommandConfirmation {
        let connection = try await connection(for: speakerID)
        try requirePoweredOn(connection.snapshot)

        let changed = connection.snapshot.source != source
        if changed {
            try await performWrite(command: "set-source", speakerID: connection.record.id) {
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

    func adjustVolume(
        by amount: Int,
        speakerID: String? = nil
    ) async throws -> SpeakerCommandConfirmation {
        guard amount != 0 else { throw SpeakerCommandError.invalidAdjustment }
        let connection = try await connection(for: speakerID)
        try requirePoweredOn(connection.snapshot)

        let target = VolumePolicy.clampedVolume(connection.snapshot.volume + amount)
        let changed = target != connection.snapshot.volume
        if changed {
            try await performWrite(command: "adjust-volume", speakerID: connection.record.id) {
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

    func setVolume(
        _ volume: Int,
        speakerID: String? = nil
    ) async throws -> SpeakerCommandConfirmation {
        guard 0...100 ~= volume else { throw SpeakerCommandError.invalidVolume }
        let connection = try await connection(for: speakerID)
        try requirePoweredOn(connection.snapshot)

        let changed = connection.snapshot.volume != volume
        if changed {
            try await performWrite(command: "set-volume", speakerID: connection.record.id) {
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

    func setMuted(
        _ shouldMute: Bool,
        speakerID: String? = nil
    ) async throws -> SpeakerCommandConfirmation {
        let connection = try await connection(for: speakerID)
        try requirePoweredOn(connection.snapshot)

        if shouldMute, connection.snapshot.volume > 0 {
            speakerRecords.rememberAudibleVolume(connection.snapshot.volume, for: connection.record.id)
        }
        let target = shouldMute
            ? 0
            : (connection.record.lastAudibleVolume ?? 20)
        let changed = connection.snapshot.volume != target
        if changed {
            try await performWrite(command: shouldMute ? "mute" : "unmute", speakerID: connection.record.id) {
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

    func setPower(
        on shouldPowerOn: Bool,
        speakerID: String? = nil
    ) async throws -> SpeakerCommandConfirmation {
        let record = try configuredSpeaker(id: speakerID)

        do {
            let connection = try await connection(to: record, retryReads: !shouldPowerOn)
            let isPoweredOn = connection.snapshot.status == .powerOn
            let changed = shouldPowerOn != isPoweredOn

            if changed {
                try await performWrite(
                    command: shouldPowerOn ? "power-on" : "standby",
                    speakerID: connection.record.id
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

    func performPlayback(
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
                try await performWrite(command: "play", speakerID: connection.record.id) {
                    try await connection.client.togglePlayPause()
                }
                isPlaying = true
            }
        case .pause:
            changed = isPlaying
            if changed {
                try await performWrite(command: "pause", speakerID: connection.record.id) {
                    try await connection.client.togglePlayPause()
                }
                isPlaying = false
            }
        case .next:
            changed = true
            try await performWrite(command: "next", speakerID: connection.record.id) {
                try await connection.client.nextTrack()
            }
        case .previous:
            changed = true
            try await performWrite(command: "previous", speakerID: connection.record.id) {
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

    static func dialogMessage(for error: Error) -> String {
        let commandError = error as? SpeakerCommandError ?? .unreachable
        return String(localized: commandError.localizedStringResource)
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
        var lastError: SpeakerCommandError = .unreachable

        for (hostIndex, host) in record.connectionHosts.enumerated() {
            let client = clientFactory(host)
            do {
                let snapshot = try await readSnapshot(from: client, retry: retryReads)
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
            do {
                return try await client.getSnapshot()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
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
                if snapshot.status != .powerOn {
                    try await performWrite(command: "power-on-after-wake", speakerID: connection.record.id) {
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
        speakerID: String,
        operation: () async throws -> Void
    ) async throws {
        let clock = ContinuousClock()
        let start = clock.now

        do {
            try await operation()
            let milliseconds = Self.milliseconds(start.duration(to: clock.now))
            Self.logger.info(
                "Speaker command \(command, privacy: .public) succeeded in \(milliseconds, privacy: .public) ms for \(speakerID, privacy: .private(mask: .hash))"
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
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
    case speakerNotFound
    case speakerInStandby
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
        case .speakerNotFound:
            "That saved speaker is no longer available in Ampestra."
        case .speakerInStandby:
            "Your speaker is in standby. Ask me to turn it on first."
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
