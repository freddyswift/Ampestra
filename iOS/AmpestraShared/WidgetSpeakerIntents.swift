import AppIntents

private let widgetSpeakerCommands = SpeakerCommandService(
    speakerRecords: SpeakerRecordStore.shared
)

private protocol WidgetSpeakerControlIntent: AppIntent, CancellableIntent {}

extension WidgetSpeakerControlIntent {
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    static var supportedModes: IntentModes { .background }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
}

struct RaiseSpeakerVolumeWidgetIntent: WidgetSpeakerControlIntent {
    static let title: LocalizedStringResource = "Turn Speaker Volume Up"
    static let description = IntentDescription(
        "Raises the default speaker volume using Ampestra's configured step."
    )
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await runWidgetSpeakerCommand {
            try await widgetSpeakerCommands.adjustVolume(direction: 1)
        }
        return .result(dialog: IntentDialog(result.message))
    }
}

struct LowerSpeakerVolumeWidgetIntent: WidgetSpeakerControlIntent {
    static let title: LocalizedStringResource = "Turn Speaker Volume Down"
    static let description = IntentDescription(
        "Lowers the default speaker volume using Ampestra's configured step."
    )
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await runWidgetSpeakerCommand {
            try await widgetSpeakerCommands.adjustVolume(direction: -1)
        }
        return .result(dialog: IntentDialog(result.message))
    }
}

struct MuteSpeakerWidgetIntent: WidgetSpeakerControlIntent {
    static let title: LocalizedStringResource = "Mute Speaker"
    static let description = IntentDescription("Mutes Ampestra's default speaker.")
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await runWidgetSpeakerCommand {
            try await widgetSpeakerCommands.setMuted(true)
        }
        return .result(dialog: IntentDialog(result.message))
    }
}

private func runWidgetSpeakerCommand(
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
