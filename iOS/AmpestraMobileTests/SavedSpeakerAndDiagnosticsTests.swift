import Foundation
import KEFCore
import XCTest
@testable import AmpestraMobile

@MainActor
final class SavedSpeakerAndDiagnosticsTests: XCTestCase {
    func testSavedSwitchPreservesDefaultAndUsesSelectedSpeakersLimit() async throws {
        let defaults = makeDefaults()
        let records = SpeakerRecordStore(defaults: defaults)
        let first = try XCTUnwrap(records.save(host: "first.local", macAddress: nil, snapshot: snapshot("First")))
        let second = try XCTUnwrap(records.save(host: "second.local", macAddress: nil, snapshot: snapshot("Second"), makeDefault: false))
        records.updateVolumePreferences(SpeakerVolumePreferences(maximumVolume: 25), for: second.id)
        let firstClient = SavedSwitchClient(host: first.host, snapshot: snapshot("First"))
        let secondClient = SavedSwitchClient(host: second.host, snapshot: snapshot("Second"))
        let store = RemoteStore(defaults: defaults, speakerRecords: records, pollingInterval: .seconds(60),
                                clientFactory: { $0 == first.host ? firstClient : secondClient })
        store.hardwareButtonsEnabled = false
        defer { store.setAppActive(false) }
        XCTAssertEqual(store.savedSpeakers.count, 2)
        store.setAppActive(true)
        try await waitUntil { store.currentSpeakerID == first.id && store.connectionState == .connected }
        store.connect(to: second)
        try await waitUntil { store.currentSpeakerID == second.id && store.connectionState == .connected }
        XCTAssertEqual(store.defaultSpeakerID, first.id)
        store.previewVolume(80)
        XCTAssertEqual(store.volume, 25)
        store.makeDefaultSpeaker(id: second.id)
        XCTAssertEqual(records.defaultSpeaker()?.id, second.id)
        XCTAssertEqual(store.currentSpeakerID, second.id)
    }

    func testSavedSwitchRejectsChangedIdentityWithoutReplacingRecord() async throws {
        let defaults = makeDefaults()
        let records = SpeakerRecordStore(defaults: defaults)
        let saved = try XCTUnwrap(records.save(host: "speaker.local", macAddress: nil, snapshot: snapshot("Expected")))
        let client = SavedSwitchClient(host: saved.host, snapshot: snapshot("Different"))
        let store = RemoteStore(defaults: defaults, speakerRecords: records, clientFactory: { _ in client })
        store.hardwareButtonsEnabled = false
        defer { store.setAppActive(false) }
        store.setAppActive(true)
        store.connect(to: saved)
        try await waitUntil { if case .failed = store.connectionState { return true }; return false }
        XCTAssertEqual(store.currentSpeakerID, saved.id)
        XCTAssertEqual(records.speaker(id: saved.id)?.name, "Expected")
        XCTAssertEqual(records.allSpeakers().count, 1)
        XCTAssertEqual(store.diagnosticHistory.categories.last, .identityChanged)
    }

    func testFailedSelectedSpeakerReconnectKeepsDefaultMACAndIdentity() async throws {
        let defaults = makeDefaults()
        let records = SpeakerRecordStore(defaults: defaults)
        let first = try XCTUnwrap(records.save(host: "first.local", macAddress: "AA:AA:AA:AA:AA:AA", snapshot: snapshot("First")))
        let second = try XCTUnwrap(records.save(host: "second.local", macAddress: "BB:BB:BB:BB:BB:BB", snapshot: snapshot("Second"), makeDefault: false))
        let firstClient = SavedSwitchClient(host: first.host, snapshot: snapshot("First"))
        let secondClient = SavedSwitchClient(host: second.host, snapshot: snapshot("Second"))
        let store = RemoteStore(defaults: defaults, speakerRecords: records, pollingInterval: .seconds(60),
                                clientFactory: { $0 == first.host ? firstClient : secondClient })
        store.hardwareButtonsEnabled = false
        defer { store.setAppActive(false) }
        store.setAppActive(true)
        try await waitUntil { store.currentSpeakerID == first.id && store.connectionState == .connected }
        await secondClient.failNextRead()
        store.connect(to: second)
        try await waitUntil { if case .failed = store.connectionState { return true }; return false }
        XCTAssertEqual(store.currentSpeakerID, second.id)
        store.setAppActive(false)
        store.setAppActive(true)
        try await waitUntil { store.connectionState == .connected }
        store.reconnectNow()
        try await waitUntil { store.connectionState == .connected }
        XCTAssertEqual(store.currentSpeakerID, second.id)
        XCTAssertEqual(records.defaultSpeaker()?.id, first.id)
        XCTAssertEqual(records.speaker(id: first.id)?.host, "first.local")
        XCTAssertEqual(records.speaker(id: first.id)?.macAddress, "AA:AA:AA:AA:AA:AA")
        XCTAssertEqual(records.speaker(id: second.id)?.macAddress, "BB:BB:BB:BB:BB:BB")
        XCTAssertEqual(records.allSpeakers().count, 2)
    }

    func testRelaunchRestoresSelectedSpeakerIndependentlyOfDefault() async throws {
        let defaults = makeDefaults()
        let records = SpeakerRecordStore(defaults: defaults)
        let first = try XCTUnwrap(records.save(host: "first.local", macAddress: nil, snapshot: snapshot("First")))
        let second = try XCTUnwrap(records.save(host: "second.local", macAddress: nil, snapshot: snapshot("Second"), makeDefault: false))
        defaults.set(" second.local ", forKey: SpeakerPreferenceKeys.manualHost)
        let firstClient = SavedSwitchClient(host: first.host, snapshot: snapshot("First"))
        let secondClient = SavedSwitchClient(host: second.host, snapshot: snapshot("Second"))
        let store = RemoteStore(defaults: defaults, speakerRecords: records, pollingInterval: .seconds(60),
                                clientFactory: { $0 == first.host ? firstClient : secondClient })
        store.hardwareButtonsEnabled = false
        defer { store.setAppActive(false) }
        store.setAppActive(true)
        try await waitUntil { store.connectionState == .connected }
        XCTAssertEqual(store.currentSpeakerID, second.id)
        XCTAssertEqual(store.currentHost, second.host)
        XCTAssertEqual(store.defaultSpeakerID, first.id)
        XCTAssertEqual(store.defaultSpeakerName, "First")
    }

    func testRelaunchFallsBackToDefaultWhenLastHostIsNotSaved() throws {
        let defaults = makeDefaults()
        let records = SpeakerRecordStore(defaults: defaults)
        let first = try XCTUnwrap(records.save(host: "first.local", macAddress: nil, snapshot: snapshot("First")))
        defaults.set("forgotten.local", forKey: SpeakerPreferenceKeys.manualHost)
        let store = RemoteStore(defaults: defaults, speakerRecords: records)
        XCTAssertEqual(store.savedSpeaker?.id, first.id)
    }

    func testDiagnosticsExcludeSensitiveStateAndRawErrorPayloads() {
        let defaults = makeDefaults()
        let records = SpeakerRecordStore(defaults: defaults)
        _ = records.save(host: "private-speaker.local", macAddress: "AA:BB:CC:DD:EE:FF", snapshot: snapshot("Private Room"))
        let store = RemoteStore(defaults: defaults, speakerRecords: records)
        store.apply(snapshot("Private Room"))
        store.currentHost = "192.168.1.44"
        store.connectionState = .failed(message: "192.168.1.44 Private Room secret-song")
        store.lastError = "raw server response secret-song"
        store.diagnosticHistory.record(.classify(SpeakerCommandError.commandRejected("private-speaker.local secret-song")))
        let report = MobileDiagnosticsReport.make(store: store)
        XCTAssertTrue(report.contains("Connection: failed"))
        XCTAssertTrue(report.contains("command-rejected"))
        XCTAssertTrue(report.contains("Version:"))
        XCTAssertTrue(report.contains("iOS:"))
        for secret in ["Private Room", "private-speaker.local", "192.168.1.44", "AA:BB:CC:DD:EE:FF", "secret-song", "raw server response"] {
            XCTAssertFalse(report.contains(secret), "Report leaked \(secret)")
        }
    }

    func testDiagnosticsHistoryIsBoundedAndClassifiesWithoutRawDescriptions() {
        var history = MobileDiagnosticHistory()
        history.record(.identityChanged)
        for _ in 0..<30 { history.record(.classify(URLError(.timedOut))) }
        XCTAssertEqual(history.categories.count, 20)
        XCTAssertEqual(Set(history.categories), [.timeout])
        XCTAssertEqual(MobileDiagnosticCategory.classify(URLError(.notConnectedToInternet)), .networkUnavailable)
        XCTAssertEqual(MobileDiagnosticCategory.classify(SpeakerCommandError.commandRejected("secret")), .commandRejected)
    }

    private func makeDefaults() -> UserDefaults {
        let name = "SavedSpeakerAndDiagnosticsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func snapshot(_ name: String) -> SpeakerSnapshot {
        SpeakerSnapshot(status: .powerOn, source: .tv, volume: 30, name: name, model: "LS60")
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected speaker state did not arrive")
    }
}

private actor SavedSwitchClient: KEFSpeakerClient {
    nonisolated let host: String
    let snapshot: SpeakerSnapshot
    init(host: String, snapshot: SpeakerSnapshot) { self.host = host; self.snapshot = snapshot }
    private var shouldFailRead = false
    func failNextRead() { shouldFailRead = true }
    func getSnapshot() async throws -> SpeakerSnapshot {
        if shouldFailRead { shouldFailRead = false; throw URLError(.timedOut) }
        return snapshot
    }
    func getStatus() async throws -> SpeakerStatus { snapshot.status }
    func getSource() async throws -> SpeakerSource { snapshot.source }
    func getVolume() async throws -> Int { snapshot.volume }
    func getSpeakerName() async throws -> String { snapshot.name }
    func getModel() async throws -> String { snapshot.model }
    func getPlayerState() async throws -> PlayerState { PlayerState(isPlaying: false, nowPlaying: NowPlayingInfo()) }
    func getIsPlaying() async throws -> Bool { false }
    func getNowPlayingInfo() async throws -> NowPlayingInfo { NowPlayingInfo() }
    func setVolume(_ volume: Int) async throws {}
    func setSource(_ source: SpeakerSource) async throws {}
    func powerOn() async throws {}
    func shutdown() async throws {}
    func togglePlayPause() async throws {}
    func nextTrack() async throws {}
    func previousTrack() async throws {}
    func testConnection() async -> Bool { true }
}
