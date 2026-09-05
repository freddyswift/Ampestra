import AppIntents
import Foundation

/// A widget keeps its selected identity even when that speaker has been forgotten.
/// Returning a tombstone from the query prevents WidgetKit treating it as an
/// unset selection and controlling a different default speaker.
struct WidgetSpeakerEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Speaker")
    static let defaultQuery = WidgetSpeakerEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name),
                              image: .init(systemName: "hifispeaker.2"))
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(record: SavedSpeaker) {
        self.init(id: record.id, name: record.displayName)
    }
}

struct WidgetSpeakerEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetSpeakerEntity] {
        Self.resolve(identifiers, records: .shared)
    }

    static func resolve(_ identifiers: [String], records: SpeakerRecordStore) -> [WidgetSpeakerEntity] {
        identifiers.map { id in
            records.speaker(id: id).map(WidgetSpeakerEntity.init)
                ?? WidgetSpeakerEntity(id: id, name: "Speaker unavailable")
        }
    }

    func suggestedEntities() async throws -> [WidgetSpeakerEntity] {
        SpeakerRecordStore.shared.allSpeakers()
            .filter { $0.requiresReconfirmation != true }
            .map(WidgetSpeakerEntity.init)
    }

    func defaultResult() async -> WidgetSpeakerEntity? {
        SpeakerRecordStore.shared.defaultSpeaker().map(WidgetSpeakerEntity.init)
    }
}

struct SelectWidgetSpeakerIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Speaker Controls"
    static let description = IntentDescription("Choose the saved speaker this widget controls.")

    @Parameter(title: "Speaker")
    var speaker: WidgetSpeakerEntity?

    init() {}

    /// An absent selection preserves existing widgets; an explicit missing ID
    /// must remain unavailable instead of falling back to another speaker.
    func selectedSpeaker(in records: SpeakerRecordStore) -> SavedSpeaker? {
        if let speaker { return records.speaker(id: speaker.id) }
        return records.defaultSpeaker()
    }
}

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
        "Raises the selected speaker volume using Ampestra's configured step."
    )
    static let isDiscoverable = false

    @Parameter(title: "Speaker ID")
    var speakerID: String?

    init() {}

    init(speakerID: String?) {
        self.speakerID = speakerID
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await runWidgetSpeakerCommand {
            try await widgetSpeakerCommands.adjustVolume(direction: 1, speakerID: speakerID)
        }
        return .result(dialog: IntentDialog(result.message))
    }
}

struct LowerSpeakerVolumeWidgetIntent: WidgetSpeakerControlIntent {
    static let title: LocalizedStringResource = "Turn Speaker Volume Down"
    static let description = IntentDescription(
        "Lowers the selected speaker volume using Ampestra's configured step."
    )
    static let isDiscoverable = false

    @Parameter(title: "Speaker ID")
    var speakerID: String?

    init() {}

    init(speakerID: String?) {
        self.speakerID = speakerID
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await runWidgetSpeakerCommand {
            try await widgetSpeakerCommands.adjustVolume(direction: -1, speakerID: speakerID)
        }
        return .result(dialog: IntentDialog(result.message))
    }
}

struct MuteSpeakerWidgetIntent: WidgetSpeakerControlIntent {
    static let title: LocalizedStringResource = "Mute or Unmute Speaker"
    static let description = IntentDescription("Toggles mute for the selected speaker using its current volume.")
    static let isDiscoverable = false

    @Parameter(title: "Speaker ID")
    var speakerID: String?

    init() {}

    init(speakerID: String?) {
        self.speakerID = speakerID
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await runWidgetSpeakerCommand {
            try await widgetSpeakerCommands.toggleMute(speakerID: speakerID)
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
