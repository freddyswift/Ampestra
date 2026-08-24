import Foundation
import KEFCore

struct SpeakerCommandService {
    typealias ClientFactory = @Sendable (String) -> KEFSpeakerClient

    private let defaults: UserDefaults
    private let clientFactory: ClientFactory

    init(
        defaults: UserDefaults = .standard,
        clientFactory: @escaping ClientFactory = { KEFSpeakerAPI(host: $0) }
    ) {
        self.defaults = defaults
        self.clientFactory = clientFactory
    }

    func setSource(_ source: SpeakerSource) async throws -> SpeakerCommandConfirmation {
        let speaker = try configuredSpeaker()
        let snapshot = try await speaker.getSnapshot()
        try requirePoweredOn(snapshot)

        if snapshot.source != source {
            try await speaker.setSource(source)
        }

        return SpeakerCommandConfirmation(
            message: "\(speakerName(from: snapshot)) is set to \(source.displayName)."
        )
    }

    func adjustVolume(by amount: Int) async throws -> SpeakerCommandConfirmation {
        let speaker = try configuredSpeaker()
        let snapshot = try await speaker.getSnapshot()
        try requirePoweredOn(snapshot)

        let target = VolumePolicy.clampedVolume(snapshot.volume + amount)
        if target != snapshot.volume {
            try await speaker.setVolume(target)
        }

        return SpeakerCommandConfirmation(
            message: "\(speakerName(from: snapshot)) volume is \(target)."
        )
    }

    func setVolume(_ volume: Int) async throws -> SpeakerCommandConfirmation {
        guard 0...100 ~= volume else {
            throw SpeakerCommandError.invalidVolume
        }

        let speaker = try configuredSpeaker()
        let snapshot = try await speaker.getSnapshot()
        try requirePoweredOn(snapshot)

        if snapshot.volume != volume {
            try await speaker.setVolume(volume)
        }

        return SpeakerCommandConfirmation(
            message: "\(speakerName(from: snapshot)) volume is \(volume)."
        )
    }

    func setPower(on shouldPowerOn: Bool) async throws -> SpeakerCommandConfirmation {
        let speaker = try configuredSpeaker()
        let snapshot = try await speaker.getSnapshot()
        let isPoweredOn = snapshot.status == .powerOn

        if shouldPowerOn != isPoweredOn {
            if shouldPowerOn {
                try await speaker.powerOn()
            } else {
                try await speaker.shutdown()
            }
        }

        let state = shouldPowerOn ? "on" : "in standby"
        return SpeakerCommandConfirmation(
            message: "\(speakerName(from: snapshot)) is \(state)."
        )
    }

    static func dialogMessage(for error: Error) -> String {
        if let commandError = error as? SpeakerCommandError {
            return commandError.errorDescription ?? "I couldn't control your speaker."
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "Your iPhone isn't connected to the speaker's network."
            case .timedOut:
                return "Your speaker didn't respond in time."
            case .cannotConnectToHost, .cannotFindHost:
                return "I couldn't reach your speaker. Make sure it is on the same network as your iPhone."
            default:
                break
            }
        }

        return "I couldn't control your speaker. Make sure it is on the same network as your iPhone."
    }

    private func configuredSpeaker() throws -> KEFSpeakerClient {
        let candidates = [
            defaults.string(forKey: SpeakerPreferenceKeys.savedHost),
            defaults.string(forKey: SpeakerPreferenceKeys.manualHost),
        ]

        guard let host = candidates.lazy.compactMap({ rawHost in
            rawHost.flatMap(ManualHostValidator.normalizedHost)
        }).first else {
            throw SpeakerCommandError.noConfiguredSpeaker
        }

        return clientFactory(host)
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
}

struct SpeakerCommandConfirmation: Equatable, Sendable {
    let message: String
}

enum SpeakerCommandError: LocalizedError, Equatable, Sendable {
    case noConfiguredSpeaker
    case speakerInStandby
    case invalidVolume

    var errorDescription: String? {
        switch self {
        case .noConfiguredSpeaker:
            "Open Ampestra and connect a speaker first."
        case .speakerInStandby:
            "Your speaker is in standby. Ask me to turn the speakers on first."
        case .invalidVolume:
            "Choose a speaker volume between 0 and 100."
        }
    }
}
