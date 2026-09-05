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

    init(unavailableID: String) {
        id = unavailableID
        name = "Speaker unavailable"
        model = ""
    }
}

struct SpeakerEntityQuery: EntityStringQuery, EnumerableEntityQuery {
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Dependency private var speakerRecords: SpeakerRecordStore

    init() {}

    func entities(for identifiers: [SpeakerEntity.ID]) async throws -> [SpeakerEntity] {
        Self.resolve(identifiers, records: speakerRecords)
    }

    static func resolve(_ identifiers: [String], records: SpeakerRecordStore) -> [SpeakerEntity] {
        let saved = Dictionary(records.allSpeakers().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Preserve missing selections just as widgets do. Clearing an optional
        // speaker parameter would let an old Shortcut target the new default.
        return identifiers.map { id in
            saved[id].map(SpeakerEntity.init) ?? SpeakerEntity(unavailableID: id)
        }
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
