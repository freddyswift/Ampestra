import AppIntents
import Foundation
import KEFCore
import XCTest
@testable import AmpestraMobile

final class SavedSpeakerPersistenceTests: XCTestCase {
    func testBlankSpeakerNameCanReconnectWithoutCreatingAnotherIdentity() throws {
        let records = makeRecords()
        let state = snapshot(name: " \n ")
        let first = try XCTUnwrap(records.save(host: "speaker.local", macAddress: nil, snapshot: state))

        XCTAssertEqual(first.displayName, "KEF Speaker")
        XCTAssertTrue(first.accepts(state))
        let reconnected = try XCTUnwrap(records.save(host: "speaker.local", macAddress: nil, snapshot: state))
        XCTAssertEqual(reconnected.id, first.id)
        XCTAssertEqual(records.allSpeakers().count, 1)
    }

    func testExplicitReconfirmationRestoresOriginalIdentityAndVolumeLimit() throws {
        let records = makeRecords()
        let original = try XCTUnwrap(records.save(host: "speaker.local", macAddress: nil,
                                                 snapshot: snapshot(name: "Living Room")))
        records.updateVolumePreferences(SpeakerVolumePreferences(maximumVolume: 20), for: original.id)
        let replacement = try XCTUnwrap(records.save(host: "speaker.local", macAddress: nil,
                                                    snapshot: snapshot(name: "Office")))
        XCTAssertFalse(try XCTUnwrap(records.speaker(id: original.id)).accepts(snapshot(name: "Living Room")))

        let restored = try XCTUnwrap(records.save(host: "speaker.local", macAddress: nil,
                                                 snapshot: snapshot(name: "Living Room")))
        XCTAssertEqual(restored.id, original.id)
        XCTAssertTrue(restored.accepts(snapshot(name: "Living Room")))
        XCTAssertEqual(records.volumePreferences(for: restored.id).effectiveMaximumVolume, 20)
        XCTAssertEqual(records.allSpeakers().count, 2)
        XCTAssertTrue(try XCTUnwrap(records.speaker(id: replacement.id)).requiresReconfirmation == true)
    }

    func testReconfirmationDoesNotReuseIdentityWithDifferentKnownMAC() throws {
        let records = makeRecords()
        let original = try XCTUnwrap(records.save(host: "speaker.local", macAddress: "AA:BB:CC:DD:EE:FF",
                                                 snapshot: snapshot(name: "Living Room")))
        let replacement = try XCTUnwrap(records.save(host: "speaker.local", macAddress: "11:22:33:44:55:66",
                                                    snapshot: snapshot(name: "Living Room")))
        XCTAssertNotEqual(replacement.id, original.id)
        XCTAssertTrue(try XCTUnwrap(records.speaker(id: original.id)).requiresReconfirmation == true)
    }

    func testManualConnectionKeepsActiveIdentityAheadOfSameNameTombstone() throws {
        let records = makeRecords()
        let state = snapshot(name: "Living Room")
        let original = try XCTUnwrap(records.save(host: "speaker.local", macAddress: "AA:BB:CC:DD:EE:FF", snapshot: state))
        let replacement = try XCTUnwrap(records.save(host: "speaker.local", macAddress: "11:22:33:44:55:66", snapshot: state))

        let manual = try XCTUnwrap(records.save(host: "speaker.local", macAddress: nil, snapshot: state))
        XCTAssertEqual(manual.id, replacement.id)
        XCTAssertEqual(manual.macAddress, replacement.macAddress)
        XCTAssertTrue(try XCTUnwrap(records.speaker(id: original.id)).requiresReconfirmation == true)
        XCTAssertEqual(records.allSpeakers().count, 2)
    }

    func testExactMACMatchTakesPriorityOverAnActiveHostWithoutMAC() throws {
        let records = makeRecords()
        let state = snapshot(name: "Living Room")
        let hostRecord = try XCTUnwrap(records.save(host: "speaker.local", macAddress: nil, snapshot: state))
        let identified = try XCTUnwrap(records.save(host: "old.local", macAddress: "AA:BB:CC:DD:EE:FF", snapshot: state))

        let moved = try XCTUnwrap(records.save(host: "speaker.local", macAddress: identified.macAddress, snapshot: state))
        XCTAssertEqual(moved.id, identified.id)
        XCTAssertTrue(try XCTUnwrap(records.speaker(id: hostRecord.id)).requiresReconfirmation == true)
        XCTAssertEqual(records.allSpeakers().count, 2)
    }

    func testManualReconfirmationDoesNotGuessBetweenSameNameTombstones() throws {
        let records = makeRecords()
        let state = snapshot(name: "Living Room")
        let first = try XCTUnwrap(records.save(host: "speaker.local", macAddress: "AA:BB:CC:DD:EE:FF", snapshot: state))
        let second = try XCTUnwrap(records.save(host: "speaker.local", macAddress: "11:22:33:44:55:66", snapshot: state))
        _ = records.save(host: "speaker.local", macAddress: nil, snapshot: snapshot(name: "Office"))

        let manual = try XCTUnwrap(records.save(host: "speaker.local", macAddress: nil, snapshot: state))
        XCTAssertNotEqual(manual.id, first.id)
        XCTAssertNotEqual(manual.id, second.id)
        XCTAssertTrue(try XCTUnwrap(records.speaker(id: first.id)).requiresReconfirmation == true)
        XCTAssertTrue(try XCTUnwrap(records.speaker(id: second.id)).requiresReconfirmation == true)
    }

    func testWidgetReloadsFollowSavedSpeakerAndDefaultChanges() throws {
        let reloads = WidgetReloadCounter()
        let records = makeRecords(reloadWidgets: { reloads.increment() })
        let first = try XCTUnwrap(records.save(host: "first.local", macAddress: nil,
                                              snapshot: snapshot(name: "First")))
        XCTAssertEqual(reloads.count, 1)
        XCTAssertTrue(records.setDefaultSpeaker(id: first.id))
        XCTAssertEqual(reloads.count, 1, "Reselecting the default needs no new timeline")
        let second = try XCTUnwrap(records.save(host: "second.local", macAddress: nil,
                                               snapshot: snapshot(name: "Second"), makeDefault: false))
        XCTAssertEqual(reloads.count, 2)
        XCTAssertTrue(records.setDefaultSpeaker(id: second.id))
        XCTAssertEqual(reloads.count, 3)
        records.remove(id: second.id)
        XCTAssertEqual(reloads.count, 4)
        XCTAssertEqual(records.defaultSpeaker()?.id, first.id)
        records.remove(id: second.id)
        XCTAssertEqual(reloads.count, 4, "Removing an absent speaker should not reload widgets")
        records.removeAll()
        XCTAssertEqual(reloads.count, 5)
        XCTAssertNil(records.defaultSpeaker())
    }

    func testEditingVolumePreferencesPersistsWithoutReloadingUnchangedWidgetContent() throws {
        let reloads = WidgetReloadCounter()
        let records = makeRecords(reloadWidgets: { reloads.increment() })
        let saved = try XCTUnwrap(records.save(host: "speaker.local", macAddress: nil,
                                              snapshot: snapshot(name: "Living Room")))
        var preferences = SpeakerVolumePreferences(maximumVolume: 25)
        records.updateVolumePreferences(preferences, for: saved.id)
        preferences.presets[0].name = "Evening"
        records.updateVolumePreferences(preferences, for: saved.id)
        records.updateVolumePreferences(preferences, for: saved.id)
        XCTAssertEqual(records.volumePreferences(for: saved.id), preferences)
        XCTAssertEqual(reloads.count, 1, "Widget actions read current preferences when invoked")
    }

    func testIdenticalWidgetPollingKeepsReloadThrottleWhileChangedVolumeReloadsImmediately() throws {
        let reloads = WidgetReloadCounter()
        let records = makeRecords(reloadWidgets: { reloads.increment() })
        let saved = try XCTUnwrap(records.save(host: "speaker.local", macAddress: nil,
                                              snapshot: snapshot(name: "Living Room")))
        let lastUpdate = try XCTUnwrap(saved.widgetReading).updatedAt
        records.updateWidgetReading(id: saved.id, volume: 35, isPoweredOn: true,
                                    now: lastUpdate.addingTimeInterval(3))
        XCTAssertEqual(reloads.count, 1)
        records.updateWidgetReading(id: saved.id, volume: 35, isPoweredOn: true,
                                    now: lastUpdate.addingTimeInterval(60))
        XCTAssertEqual(reloads.count, 2)
        records.updateWidgetReading(id: saved.id, volume: 40, isPoweredOn: true,
                                    now: lastUpdate.addingTimeInterval(61))
        XCTAssertEqual(reloads.count, 3)
    }

    func testShortcutEntityResolutionPreservesOrderAndForgottenSpeakerIdentity() throws {
        let records = makeRecords()
        let forgotten = try XCTUnwrap(records.save(host: "first.local", macAddress: nil,
                                                  snapshot: snapshot(name: "First")))
        let current = try XCTUnwrap(records.save(host: "second.local", macAddress: nil,
                                                snapshot: snapshot(name: "Second")))
        records.remove(id: forgotten.id)

        let entities = SpeakerEntityQuery.resolve([current.id, forgotten.id], records: records)
        XCTAssertEqual(entities.map(\.id), [current.id, forgotten.id])
        XCTAssertEqual(entities.map(\.name), ["Second", "Speaker unavailable"])
        XCTAssertNil(records.speaker(id: entities[1].id), "A forgotten Shortcut must keep its unavailable target")
        XCTAssertEqual(records.defaultSpeaker()?.id, current.id)
    }

    func testWidgetEntityResolutionPreservesRequestedOrderAndUnavailableSelections() throws {
        let records = makeRecords()
        let first = try XCTUnwrap(records.save(host: "first.local", macAddress: nil,
                                              snapshot: snapshot(name: "First")))
        let second = try XCTUnwrap(records.save(host: "second.local", macAddress: nil,
                                               snapshot: snapshot(name: "Second")))
        let identifiers = [second.id, "missing", first.id]
        let entities = WidgetSpeakerEntityQuery.resolve(identifiers, records: records)
        XCTAssertEqual(entities.map(\.id), identifiers)
        XCTAssertEqual(entities.map(\.name), ["Second", "Speaker unavailable", "First"])
    }

    private func makeRecords(reloadWidgets: @escaping @Sendable () -> Void = {}) -> SpeakerRecordStore {
        let suite = "SavedSpeakerPersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return SpeakerRecordStore(defaults: defaults, reloadWidgets: reloadWidgets)
    }

    private func snapshot(name: String) -> SpeakerSnapshot {
        SpeakerSnapshot(status: .powerOn, source: .wifi, volume: 35, name: name, model: "LS60")
    }
}

private final class WidgetReloadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func increment() {
        lock.withLock { value += 1 }
    }
}
