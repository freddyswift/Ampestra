import AppIntents
import Foundation
import XCTest
@testable import AmpestraMobile
import KEFCore

final class WidgetSpeakerSelectionTests: XCTestCase {
    func testSelectedWidgetRetainsTargetWhenDefaultChanges() throws {
        let records = makeRecords()
        let first = try save("living.local", name: "Living Room", in: records)
        var configuration = SelectWidgetSpeakerIntent()
        configuration.speaker = WidgetSpeakerEntity(record: first)
        let second = try save("kitchen.local", name: "Kitchen", in: records)

        XCTAssertEqual(records.defaultSpeaker()?.id, second.id)
        XCTAssertEqual(configuration.selectedSpeaker(in: records)?.id, first.id)
    }

    func testForgottenSelectedSpeakerDoesNotFallBackToDefault() throws {
        let records = makeRecords()
        let first = try save("living.local", name: "Living Room", in: records)
        let second = try save("kitchen.local", name: "Kitchen", in: records)
        records.remove(id: first.id)

        let resolved = WidgetSpeakerEntityQuery.resolve([first.id], records: records)
        XCTAssertEqual(resolved.map(\.id), [first.id], "Keep a tombstone so WidgetKit cannot clear the selection")
        var configuration = SelectWidgetSpeakerIntent()
        configuration.speaker = try XCTUnwrap(resolved.first)
        XCTAssertNil(configuration.selectedSpeaker(in: records))
        XCTAssertEqual(records.defaultSpeaker()?.id, second.id)
    }

    func testExistingUnconfiguredWidgetUsesDefaultSpeaker() throws {
        let records = makeRecords()
        let saved = try save("living.local", name: "Living Room", in: records)
        XCTAssertEqual(SelectWidgetSpeakerIntent().selectedSpeaker(in: records)?.id, saved.id)
    }

    func testEveryWidgetActionCarriesTheRenderedSpeakerIdentity() {
        let id = UUID().uuidString
        XCTAssertEqual(LowerSpeakerVolumeWidgetIntent(speakerID: id).speakerID, id)
        XCTAssertEqual(RaiseSpeakerVolumeWidgetIntent(speakerID: id).speakerID, id)
        XCTAssertEqual(MuteSpeakerWidgetIntent(speakerID: id).speakerID, id)
    }

    private func makeRecords() -> SpeakerRecordStore {
        let suite = "WidgetSpeakerSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return SpeakerRecordStore(defaults: defaults)
    }

    private func save(_ host: String, name: String, in records: SpeakerRecordStore) throws -> SavedSpeaker {
        try XCTUnwrap(records.save(host: host, macAddress: nil,
                                  snapshot: SpeakerSnapshot(status: .powerOn, source: .wifi,
                                                            volume: 35, name: name, model: "LS60")))
    }
}
