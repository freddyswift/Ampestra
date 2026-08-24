import AppIntents
import Foundation

struct SpeakerEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Speaker",
        numericFormat: "\(placeholder: .int) speakers",
        synonyms: ["KEF speaker", "speakers"]
    )
    static let defaultQuery = SpeakerEntityQuery()

    let id: String

    @Property(title: "Name")
    var name: String

    @Property(title: "Model")
    var model: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: name),
            subtitle: model.isEmpty ? nil : LocalizedStringResource(stringLiteral: model),
            image: .init(systemName: "hifispeaker.2"),
            synonyms: ["KEF", "speakers"]
        )
    }

    init(record: SavedSpeaker) {
        id = record.id
        name = record.displayName
        model = record.model
    }
}

struct SpeakerEntityQuery: EntityStringQuery, EnumerableEntityQuery {
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Dependency private var speakerRecords: SpeakerRecordStore

    init() {}

    func entities(for identifiers: [SpeakerEntity.ID]) async throws -> [SpeakerEntity] {
        let requested = Set(identifiers)
        return speakerRecords.allSpeakers()
            .filter { requested.contains($0.id) }
            .map(SpeakerEntity.init)
    }

    func entities(matching string: String) async throws -> [SpeakerEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return try await allEntities() }

        return speakerRecords.allSpeakers()
            .filter { record in
                record.displayName.localizedCaseInsensitiveContains(query)
                    || record.model.localizedCaseInsensitiveContains(query)
            }
            .map(SpeakerEntity.init)
    }

    func allEntities() async throws -> [SpeakerEntity] {
        speakerRecords.allSpeakers().map(SpeakerEntity.init)
    }

    func defaultResult() async -> SpeakerEntity? {
        speakerRecords.defaultSpeaker().map(SpeakerEntity.init)
    }
}
