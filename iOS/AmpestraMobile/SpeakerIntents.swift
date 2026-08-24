import AppIntents
import Foundation
import KEFCore

protocol BackgroundSpeakerIntent: AppIntent {}

extension BackgroundSpeakerIntent {
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }
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
        SpeakerSource(rawValue: rawValue) ?? .wifi
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

    var adjustment: Int { self == .up ? 5 : -5 }
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

struct SetSpeakerSourceIntent: BackgroundSpeakerIntent {
    static let title: LocalizedStringResource = "Set Speaker Source"
    static let description = IntentDescription("Changes the input used by your configured speaker.")

    @Parameter(title: "Source", requestValueDialog: "Which speaker source?")
    var source: SpeakerIntentSource

    static var parameterSummary: some ParameterSummary {
        Summary("Set speakers to \(\.$source)")
    }

    func perform() async -> some IntentResult & ProvidesDialog {
        await speakerIntentResult {
            try await SpeakerCommandService().setSource(source.speakerSource)
        }
    }
}

struct AdjustSpeakerVolumeIntent: BackgroundSpeakerIntent {
    static let title: LocalizedStringResource = "Adjust Speaker Volume"
    static let description = IntentDescription("Turns your configured speaker volume up or down by 5.")

    @Parameter(title: "Direction", requestValueDialog: "Volume up or down?")
    var direction: SpeakerVolumeDirection

    static var parameterSummary: some ParameterSummary {
        Summary("Turn speaker volume \(\.$direction)")
    }

    func perform() async -> some IntentResult & ProvidesDialog {
        await speakerIntentResult {
            try await SpeakerCommandService().adjustVolume(by: direction.adjustment)
        }
    }
}

struct SetSpeakerVolumeIntent: BackgroundSpeakerIntent {
    static let title: LocalizedStringResource = "Set Speaker Volume"
    static let description = IntentDescription("Sets your configured speaker to a volume from 0 to 100.")

    @Parameter(
        title: "Volume",
        inclusiveRange: (0, 100),
        requestValueDialog: "What speaker volume?"
    )
    var volume: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set speaker volume to \(\.$volume)")
    }

    func perform() async -> some IntentResult & ProvidesDialog {
        await speakerIntentResult {
            try await SpeakerCommandService().setVolume(volume)
        }
    }
}

struct SetSpeakerPowerIntent: BackgroundSpeakerIntent {
    static let title: LocalizedStringResource = "Set Speaker Power"
    static let description = IntentDescription("Turns your configured speaker on or puts it in standby.")

    @Parameter(title: "Power", requestValueDialog: "Turn the speakers on or off?")
    var state: SpeakerPowerState

    static var parameterSummary: some ParameterSummary {
        Summary("Turn speakers \(\.$state)")
    }

    func perform() async -> some IntentResult & ProvidesDialog {
        await speakerIntentResult {
            try await SpeakerCommandService().setPower(on: state == .on)
        }
    }
}

struct AmpestraShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetSpeakerSourceIntent(),
            phrases: [
                "Speakers \(\.$source) with \(.applicationName)",
                "Set speakers to \(\.$source) with \(.applicationName)",
                "Switch speakers to \(\.$source) using \(.applicationName)",
            ],
            shortTitle: "Set Speaker Source",
            systemImageName: "hifispeaker.2"
        )

        AppShortcut(
            intent: AdjustSpeakerVolumeIntent(),
            phrases: [
                "Speakers volume \(\.$direction) with \(.applicationName)",
                "Turn speakers \(\.$direction) with \(.applicationName)",
                "Adjust speakers \(\.$direction) using \(.applicationName)",
            ],
            shortTitle: "Adjust Speaker Volume",
            systemImageName: "speaker.wave.2"
        )

        AppShortcut(
            intent: SetSpeakerPowerIntent(),
            phrases: [
                "Speakers \(\.$state) with \(.applicationName)",
                "Turn speakers \(\.$state) with \(.applicationName)",
            ],
            shortTitle: "Set Speaker Power",
            systemImageName: "power"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .teal
}

private func speakerIntentResult(
    _ operation: () async throws -> SpeakerCommandConfirmation
) async -> some IntentResult & ProvidesDialog {
    let message: String
    do {
        message = try await operation().message
    } catch {
        message = SpeakerCommandService.dialogMessage(for: error)
    }

    return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: message)))
}
