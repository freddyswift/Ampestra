import AppIntents
import Foundation
import KEFCore

protocol BackgroundSpeakerIntent: AppIntent, CancellableIntent {}

extension BackgroundSpeakerIntent {
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    static var supportedModes: IntentModes { .background }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
}

enum SpeakerIntentSource: String, AppEnum {
    case wifi
    case bluetooth
    case tv
    case optical
    case coaxial
    case analog
    case usb

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Speaker Source")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .wifi: DisplayRepresentation(title: "Wi‑Fi", synonyms: ["WiFi", "wireless"]),
        .bluetooth: "Bluetooth",
        .tv: DisplayRepresentation(title: "TV", synonyms: ["television"]),
        .optical: "Optical",
        .coaxial: DisplayRepresentation(title: "Coaxial", synonyms: ["coax"]),
        .analog: DisplayRepresentation(title: "Analog", synonyms: ["aux", "auxiliary"]),
        .usb: "USB",
    ]

    var speakerSource: SpeakerSource {
        switch self {
        case .wifi: .wifi
        case .bluetooth: .bluetooth
        case .tv: .tv
        case .optical: .optical
        case .coaxial: .coaxial
        case .analog: .analog
        case .usb: .usb
        }
    }
}

enum SpeakerVolumeDirection: String, AppEnum {
    case up
    case down

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Volume Direction")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .up: DisplayRepresentation(title: "Up", synonyms: ["louder", "increase"]),
        .down: DisplayRepresentation(title: "Down", synonyms: ["quieter", "decrease"]),
    ]

    var direction: Int { self == .up ? 1 : -1 }
}

enum SpeakerPowerState: String, AppEnum {
    case on
    case off

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Power State")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .on: DisplayRepresentation(title: "On", synonyms: ["awake", "wake up"]),
        .off: DisplayRepresentation(title: "Off", synonyms: ["standby", "sleep"]),
    ]
}

enum SpeakerMuteState: String, AppEnum {
    case mute
    case unmute

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Mute State")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .mute: DisplayRepresentation(title: "Mute", synonyms: ["silent", "silence"]),
        .unmute: DisplayRepresentation(title: "Unmute", synonyms: ["restore sound"]),
    ]
}

enum SpeakerPlaybackAction: String, AppEnum {
    case play
    case pause
    case next
    case previous

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playback Action")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .play: DisplayRepresentation(title: "Play", synonyms: ["resume"]),
        .pause: "Pause",
        .next: DisplayRepresentation(title: "Next", synonyms: ["skip", "skip forward"]),
        .previous: DisplayRepresentation(title: "Previous", synonyms: ["back", "skip back"]),
    ]

    var command: SpeakerPlaybackCommand {
        switch self {
        case .play: .play
        case .pause: .pause
        case .next: .next
        case .previous: .previous
        }
    }
}

struct SetSpeakerSourceIntent: BackgroundSpeakerIntent {
    static let title: LocalizedStringResource = "Set Speaker Source"
    static let description = IntentDescription(
        "Changes the input used by a saved speaker.",
        categoryName: "Speaker Control",
        searchKeywords: ["input", "source", "KEF"]
    )

    @Parameter(title: "Source", requestValueDialog: "Which speaker source?")
    var source: SpeakerIntentSource

    @Parameter(title: "Speaker", requestValueDialog: "Which speaker?")
    var speaker: SpeakerEntity?

    @Dependency private var speakerCommands: SpeakerCommandService

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$speaker) to \(\.$source)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<SpeakerIntentSource> {
        let result = try await runSpeakerCommand {
            try await speakerCommands.setSource(source.speakerSource, speakerID: speaker?.id)
        }
        return .result(value: source, dialog: IntentDialog(result.message))
    }
}

struct AdjustSpeakerVolumeIntent: BackgroundSpeakerIntent {
    static let title: LocalizedStringResource = "Adjust Speaker Volume"
    static let description = IntentDescription(
        "Turns a saved speaker up or down using Ampestra's configured volume step.",
        categoryName: "Speaker Control",
        searchKeywords: ["volume", "louder", "quieter", "KEF"]
    )

    @Parameter(title: "Direction", requestValueDialog: "Volume up or down?")
    var direction: SpeakerVolumeDirection

    @Parameter(title: "Speaker", requestValueDialog: "Which speaker?")
    var speaker: SpeakerEntity?

    @Dependency private var speakerCommands: SpeakerCommandService

    static var parameterSummary: some ParameterSummary {
        Summary("Turn \(\.$speaker) volume \(\.$direction)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        let result = try await runSpeakerCommand {
            try await speakerCommands.adjustVolume(direction: direction.direction, speakerID: speaker?.id)
        }
        return .result(value: result.volume, dialog: IntentDialog(result.message))
    }
}

struct SetSpeakerVolumeIntent: BackgroundSpeakerIntent {
    static let title: LocalizedStringResource = "Set Speaker Volume"
    static let description = IntentDescription(
        "Sets a saved speaker to a volume from 0 to 100.",
        categoryName: "Speaker Control",
        searchKeywords: ["volume", "level", "KEF"]
    )

    @Parameter(
        title: "Volume",
        inclusiveRange: (0, 100),
        requestValueDialog: "What speaker volume?"
    )
    var volume: Int

    @Parameter(title: "Speaker", requestValueDialog: "Which speaker?")
    var speaker: SpeakerEntity?

    @Dependency private var speakerCommands: SpeakerCommandService

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$speaker) volume to \(\.$volume)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        let result = try await runSpeakerCommand {
            try await speakerCommands.setVolume(volume, speakerID: speaker?.id)
        }
        return .result(value: result.volume, dialog: IntentDialog(result.message))
    }
}

struct SetSpeakerMuteIntent: BackgroundSpeakerIntent {
    static let title: LocalizedStringResource = "Mute or Unmute Speaker"
    static let description = IntentDescription(
        "Mutes a saved speaker or restores its previous audible volume.",
        categoryName: "Speaker Control",
        searchKeywords: ["mute", "unmute", "silence", "KEF"]
    )

    @Parameter(title: "Action", requestValueDialog: "Mute or unmute the speaker?")
    var state: SpeakerMuteState

    @Parameter(title: "Speaker", requestValueDialog: "Which speaker?")
    var speaker: SpeakerEntity?

    @Dependency private var speakerCommands: SpeakerCommandService

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$state) \(\.$speaker)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        let result = try await runSpeakerCommand {
            try await speakerCommands.setMuted(state == .mute, speakerID: speaker?.id)
        }
        return .result(value: result.volume, dialog: IntentDialog(result.message))
    }
}

struct SetSpeakerPowerIntent: BackgroundSpeakerIntent {
    static let title: LocalizedStringResource = "Set Speaker Power"
    static let description = IntentDescription(
        "Turns a saved speaker on or puts it in standby.",
        categoryName: "Speaker Control",
        searchKeywords: ["power", "wake", "standby", "KEF"]
    )

    @Parameter(title: "Power", requestValueDialog: "Turn the speaker on or off?")
    var state: SpeakerPowerState

    @Parameter(title: "Speaker", requestValueDialog: "Which speaker?")
    var speaker: SpeakerEntity?

    @Dependency private var speakerCommands: SpeakerCommandService

    static var parameterSummary: some ParameterSummary {
        Summary("Turn \(\.$speaker) \(\.$state)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Bool> {
        let shouldPowerOn = state == .on
        let result = try await runSpeakerCommand {
            try await speakerCommands.setPower(on: shouldPowerOn, speakerID: speaker?.id)
        }
        return .result(value: shouldPowerOn, dialog: IntentDialog(result.message))
    }
}

struct ControlSpeakerPlaybackIntent: BackgroundSpeakerIntent {
    static let title: LocalizedStringResource = "Control Speaker Playback"
    static let description = IntentDescription(
        "Controls Wi‑Fi or Bluetooth playback on a saved speaker.",
        categoryName: "Speaker Control",
        searchKeywords: ["play", "pause", "next", "previous", "KEF"]
    )

    @Parameter(title: "Action", requestValueDialog: "What playback action?")
    var action: SpeakerPlaybackAction

    @Parameter(title: "Speaker", requestValueDialog: "Which speaker?")
    var speaker: SpeakerEntity?

    @Dependency private var speakerCommands: SpeakerCommandService

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action) on \(\.$speaker)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Bool> {
        let result = try await runSpeakerCommand {
            try await speakerCommands.performPlayback(action.command, speakerID: speaker?.id)
        }
        return .result(value: result.isPlaying ?? false, dialog: IntentDialog(result.message))
    }
}

struct GetSpeakerStatusIntent: BackgroundSpeakerIntent {
    static let title: LocalizedStringResource = "Get Speaker Status"
    static let description = IntentDescription(
        "Gets the power, source, and volume of a saved speaker.",
        categoryName: "Speaker Control",
        searchKeywords: ["status", "volume", "source", "power", "KEF"],
        resultValueName: "Speaker Status"
    )

    @Parameter(title: "Speaker", requestValueDialog: "Which speaker?")
    var speaker: SpeakerEntity?

    @Dependency private var speakerCommands: SpeakerCommandService

    static var parameterSummary: some ParameterSummary {
        Summary("Get status of \(\.$speaker)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let result = try await runSpeakerCommand {
            try await speakerCommands.status(speakerID: speaker?.id)
        }
        let status = String(localized: result.message)
        return .result(value: status, dialog: IntentDialog(result.message))
    }
}

struct AmpestraShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetSpeakerSourceIntent(),
            phrases: [
                "Set speakers to \(\.$source) with \(.applicationName)",
                "Switch speakers to \(\.$source) using \(.applicationName)",
                "Change the source on \(\.$speaker) with \(.applicationName)",
            ],
            shortTitle: "Set Speaker Source",
            systemImageName: "hifispeaker.2"
        )

        AppShortcut(
            intent: SetSpeakerVolumeIntent(),
            phrases: [
                "Set speaker volume with \(.applicationName)",
                "Set \(\.$speaker) volume with \(.applicationName)",
            ],
            shortTitle: "Set Speaker Volume",
            systemImageName: "speaker.wave.2"
        )

        AppShortcut(
            intent: AdjustSpeakerVolumeIntent(),
            phrases: [
                "Turn speakers \(\.$direction) with \(.applicationName)",
                "Adjust speakers \(\.$direction) using \(.applicationName)",
                "Adjust volume on \(\.$speaker) with \(.applicationName)",
            ],
            shortTitle: "Adjust Speaker Volume",
            systemImageName: "speaker.plus"
        )

        AppShortcut(
            intent: SetSpeakerMuteIntent(),
            phrases: [
                "\(\.$state) speakers with \(.applicationName)",
                "Change mute on \(\.$speaker) with \(.applicationName)",
            ],
            shortTitle: "Mute Speaker",
            systemImageName: "speaker.slash"
        )

        AppShortcut(
            intent: SetSpeakerPowerIntent(),
            phrases: [
                "Turn speakers \(\.$state) with \(.applicationName)",
                "Speakers \(\.$state) with \(.applicationName)",
                "Change power on \(\.$speaker) with \(.applicationName)",
            ],
            shortTitle: "Set Speaker Power",
            systemImageName: "power"
        )

        AppShortcut(
            intent: ControlSpeakerPlaybackIntent(),
            phrases: [
                "\(\.$action) speakers with \(.applicationName)",
                "Control playback on \(\.$speaker) with \(.applicationName)",
            ],
            shortTitle: "Control Playback",
            systemImageName: "playpause"
        )

        AppShortcut(
            intent: GetSpeakerStatusIntent(),
            phrases: [
                "Get speaker status with \(.applicationName)",
                "Get status of \(\.$speaker) with \(.applicationName)",
            ],
            shortTitle: "Get Speaker Status",
            systemImageName: "info.circle"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .teal
}

private func runSpeakerCommand(
    _ operation: () async throws -> SpeakerCommandConfirmation
) async throws -> SpeakerCommandConfirmation {
    do {
        return try await operation()
    } catch is CancellationError {
        throw CancellationError()
    } catch let error as SpeakerCommandError {
        throw AppIntentError(wrapping: error)
    } catch {
        throw AppIntentError(
            predefinedError: .Unrecoverable.networkFailure,
            description: "Ampestra couldn't control your speaker."
        )
    }
}
