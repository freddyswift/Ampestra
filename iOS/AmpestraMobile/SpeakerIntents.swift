import AppIntents
import Foundation
import KEFCore
import SwiftUI

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
        .wifi: DisplayRepresentation(
            title: "Wi‑Fi",
            image: .init(systemName: "wifi"),
            synonyms: ["WiFi", "wireless"]
        ),
        .bluetooth: DisplayRepresentation(
            title: "Bluetooth",
            image: .init(systemName: "antenna.radiowaves.left.and.right")
        ),
        .tv: DisplayRepresentation(
            title: "TV",
            image: .init(systemName: "tv"),
            synonyms: ["television"]
        ),
        .optical: DisplayRepresentation(
            title: "Optical",
            image: .init(systemName: "opticaldisc")
        ),
        .coaxial: DisplayRepresentation(
            title: "Coaxial",
            image: .init(systemName: "cable.connector"),
            synonyms: ["coax"]
        ),
        .analog: DisplayRepresentation(
            title: "Analog",
            image: .init(systemName: "waveform"),
            synonyms: ["aux", "auxiliary"]
        ),
        .usb: DisplayRepresentation(
            title: "USB",
            image: .init(systemName: "cable.connector.horizontal")
        ),
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
        .up: DisplayRepresentation(
            title: "Up",
            image: .init(systemName: "speaker.plus.fill"),
            synonyms: ["louder", "increase"]
        ),
        .down: DisplayRepresentation(
            title: "Down",
            image: .init(systemName: "speaker.minus.fill"),
            synonyms: ["quieter", "decrease"]
        ),
    ]

    var direction: Int { self == .up ? 1 : -1 }
}

enum SpeakerPowerState: String, AppEnum {
    case on
    case off

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Power State")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .on: DisplayRepresentation(
            title: "On",
            image: .init(systemName: "power"),
            synonyms: ["awake", "wake up"]
        ),
        .off: DisplayRepresentation(
            title: "Off",
            image: .init(systemName: "moon.zzz.fill"),
            synonyms: ["standby", "sleep"]
        ),
    ]
}

enum SpeakerMuteState: String, AppEnum {
    case mute
    case unmute

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Mute State")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .mute: DisplayRepresentation(
            title: "Mute",
            image: .init(systemName: "speaker.slash.fill"),
            synonyms: ["silent", "silence"]
        ),
        .unmute: DisplayRepresentation(
            title: "Unmute",
            image: .init(systemName: "speaker.wave.2.fill"),
            synonyms: ["restore sound"]
        ),
    ]
}

enum SpeakerPlaybackAction: String, AppEnum {
    case play
    case pause
    case next
    case previous

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playback Action")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .play: DisplayRepresentation(
            title: "Play",
            image: .init(systemName: "play.fill"),
            synonyms: ["resume"]
        ),
        .pause: DisplayRepresentation(
            title: "Pause",
            image: .init(systemName: "pause.fill")
        ),
        .next: DisplayRepresentation(
            title: "Skip Forward",
            image: .init(systemName: "forward.end.fill"),
            synonyms: ["next", "skip"]
        ),
        .previous: DisplayRepresentation(
            title: "Skip Back",
            image: .init(systemName: "backward.end.fill"),
            synonyms: ["previous", "back"]
        ),
    ]

    var command: SpeakerPlaybackCommand {
        switch self {
        case .play: .play
        case .pause: .pause
        case .next: .next
        case .previous: .previous
        }
    }

    var resultTitle: String {
        switch self {
        case .play: "Playing"
        case .pause: "Paused"
        case .next: "Skipped forward"
        case .previous: "Skipped back"
        }
    }

    var systemImage: String {
        switch self {
        case .play: "play.fill"
        case .pause: "pause.fill"
        case .next: "forward.end.fill"
        case .previous: "backward.end.fill"
        }
    }
}

struct WirelessSpeakerSourceOptions: DynamicOptionsProvider {
    func results() async throws -> [SpeakerIntentSource] {
        [.wifi, .bluetooth]
    }
}

struct WiredSpeakerSourceOptions: DynamicOptionsProvider {
    func results() async throws -> [SpeakerIntentSource] {
        [.tv, .optical, .coaxial, .analog, .usb]
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

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<SpeakerIntentSource> & ShowsSnippetView {
        let result = try await runSpeakerCommand {
            try await speakerCommands.setSource(source.speakerSource, speakerID: speaker?.id)
        }
        return .result(
            value: source,
            dialog: IntentDialog(result.message),
            view: SpeakerIntentResultView(
                confirmation: result,
                headline: result.source.displayName,
                systemImage: result.source.systemImage
            )
        )
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

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> & ShowsSnippetView {
        let result = try await runSpeakerCommand {
            try await speakerCommands.adjustVolume(direction: direction.direction, speakerID: speaker?.id)
        }
        return .result(
            value: result.volume,
            dialog: IntentDialog(result.message),
            view: SpeakerIntentResultView(
                confirmation: result,
                headline: "Volume \(result.volume)",
                systemImage: direction == .up ? "speaker.plus.fill" : "speaker.minus.fill"
            )
        )
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

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> & ShowsSnippetView {
        let result = try await runSpeakerCommand {
            try await speakerCommands.setVolume(volume, speakerID: speaker?.id)
        }
        return .result(
            value: result.volume,
            dialog: IntentDialog(result.message),
            view: SpeakerIntentResultView(
                confirmation: result,
                headline: "Volume \(result.volume)",
                systemImage: "speaker.wave.2.fill"
            )
        )
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

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> & ShowsSnippetView {
        let result = try await runSpeakerCommand {
            try await speakerCommands.setMuted(state == .mute, speakerID: speaker?.id)
        }
        return .result(
            value: result.volume,
            dialog: IntentDialog(result.message),
            view: SpeakerIntentResultView(
                confirmation: result,
                headline: state == .mute ? "Muted" : "Unmuted",
                systemImage: state == .mute ? "speaker.slash.fill" : "speaker.wave.2.fill"
            )
        )
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

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Bool> & ShowsSnippetView {
        let shouldPowerOn = state == .on
        let result = try await runSpeakerCommand {
            try await speakerCommands.setPower(on: shouldPowerOn, speakerID: speaker?.id)
        }
        return .result(
            value: shouldPowerOn,
            dialog: IntentDialog(result.message),
            view: SpeakerIntentResultView(
                confirmation: result,
                headline: shouldPowerOn ? "On" : "Standby",
                systemImage: shouldPowerOn ? "power" : "moon.zzz.fill"
            )
        )
    }
}

struct ControlSpeakerPlaybackIntent: BackgroundSpeakerIntent, AudioPlaybackIntent {
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

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Bool> & ShowsSnippetView {
        let result = try await runSpeakerCommand {
            try await speakerCommands.performPlayback(action.command, speakerID: speaker?.id)
        }
        return .result(
            value: result.isPlaying ?? false,
            dialog: IntentDialog(result.message),
            view: SpeakerIntentResultView(
                confirmation: result,
                headline: action.resultTitle,
                systemImage: action.systemImage
            )
        )
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

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> & ShowsSnippetView {
        let result = try await runSpeakerCommand {
            try await speakerCommands.status(speakerID: speaker?.id)
        }
        let status = String(localized: result.message)
        return .result(
            value: status,
            dialog: IntentDialog(result.message),
            view: SpeakerIntentResultView(
                confirmation: result,
                headline: result.status.displayName,
                systemImage: result.status.systemImage
            )
        )
    }
}

struct AmpestraShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AdjustSpeakerVolumeIntent(),
            phrases: [
                "Turn speakers \(\.$direction) with \(.applicationName)",
                "Adjust speaker volume with \(.applicationName)",
            ],
            shortTitle: "Adjust Volume",
            systemImageName: "speaker.plus"
        )

        AppShortcut(
            intent: SetSpeakerVolumeIntent(),
            phrases: [
                "Set speaker volume with \(.applicationName)",
            ],
            shortTitle: "Set Volume",
            systemImageName: "speaker.wave.2"
        )

        AppShortcut(
            intent: SetSpeakerPowerIntent(),
            phrases: [
                "Turn speakers \(\.$state) with \(.applicationName)",
                "Change speaker power with \(.applicationName)",
            ],
            shortTitle: "Speaker Power",
            systemImageName: "power"
        )

        AppShortcut(
            intent: SetSpeakerSourceIntent(),
            phrases: [
                "Set speakers to \(\.$source) with \(.applicationName)",
                "Change speaker source with \(.applicationName)",
            ],
            shortTitle: "Set Source",
            systemImageName: "hifispeaker.2",
            parameterPresentation: ParameterPresentation(
                for: \.$source,
                summary: Summary("Set speakers to \(\.$source)")
            ) {
                OptionsCollection(
                    WirelessSpeakerSourceOptions(),
                    title: "Wireless",
                    systemImageName: "wifi"
                )
                OptionsCollection(
                    WiredSpeakerSourceOptions(),
                    title: "Inputs",
                    systemImageName: "cable.connector"
                )
            }
        )

        AppShortcut(
            intent: SetSpeakerMuteIntent(),
            phrases: [
                "\(\.$state) speakers with \(.applicationName)",
                "Change speaker mute with \(.applicationName)",
            ],
            shortTitle: "Mute or Unmute",
            systemImageName: "speaker.slash"
        )

        AppShortcut(
            intent: ControlSpeakerPlaybackIntent(),
            phrases: [
                "\(\.$action) with \(.applicationName)",
                "Control speaker playback with \(.applicationName)",
            ],
            shortTitle: "Control Playback",
            systemImageName: "playpause"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .teal
}

private struct SpeakerIntentResultView: View {
    let confirmation: SpeakerCommandConfirmation
    let headline: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.cyan)
                .frame(width: 48, height: 48)
                .background(Color.cyan.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(confirmation.speakerName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding()
    }

    private var detail: String {
        if confirmation.status == .powerOn {
            return "\(confirmation.source.displayName) · Volume \(confirmation.volume)"
        }
        return confirmation.status.detailText
    }
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
