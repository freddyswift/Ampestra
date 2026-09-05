import XCTest
@testable import AmpestraMobile
@testable import KEFCore

@MainActor
final class SpeakerVolumeLimitTests: XCTestCase {
    func testAbsoluteRelativeAndMuteRestoreRespectPersistedLimit() async throws {
        let (records, id, client, service) = try fixture(volume: 30)
        records.updateVolumePreferences(SpeakerVolumePreferences(maximumVolume: 40), for: id)
        let absolute = try await service.setVolume(90, speakerID: id)
        XCTAssertEqual(absolute.volume, 40)
        let relative = try await service.adjustVolume(by: 25, speakerID: id)
        XCTAssertEqual(relative.volume, 40)
        _ = try await service.setMuted(true, speakerID: id)
        records.updateVolumePreferences(SpeakerVolumePreferences(maximumVolume: 15), for: id)
        let restored = try await service.setMuted(false, speakerID: id)
        XCTAssertEqual(restored.volume, 15)
        let writes = await client.writes
        XCTAssertEqual(writes, [40, 0, 15])
    }

    func testToggleUsesLiveVolumeWhenWidgetReadingDisagrees() async throws {
        let (records, id, client, service) = try fixture(volume: 0)
        records.rememberAudibleVolume(55, for: id)
        records.updateWidgetReading(id: id, volume: 55, isPoweredOn: true)
        records.updateVolumePreferences(SpeakerVolumePreferences(maximumVolume: 25), for: id)
        let result = try await service.toggleMute(speakerID: id)
        XCTAssertEqual(result.volume, 25)
        let writes = await client.writes
        XCTAssertEqual(writes, [25])
    }

    func testLimitChangedDuringConnectionReadAppliesBeforeWrite() async throws {
        let (records, id, client, service) = try fixture(volume: 30)
        let gate = VolumeReadGate()
        await client.setReadGate(gate)
        let command = Task { try await service.setVolume(90, speakerID: id) }
        await gate.waitUntilEntered()
        records.updateVolumePreferences(SpeakerVolumePreferences(maximumVolume: 12), for: id)
        await gate.release()
        let result = try await command.value
        XCTAssertEqual(result.volume, 12)
        let writes = await client.writes
        XCTAssertEqual(writes, [12])
    }

    func testPreferencesRemainPerSpeakerAndSurviveRefresh() throws {
        let (records, id, _, _) = try fixture(volume: 30)
        records.updateVolumePreferences(SpeakerVolumePreferences(maximumVolume: 22), for: id)
        _ = records.save(host: "living.local", macAddress: nil, snapshot: snapshot(volume: 60))
        let second = try XCTUnwrap(records.save(host: "bedroom.local", macAddress: nil, snapshot: snapshot(volume: 30)))
        XCTAssertEqual(records.volumePreferences(for: id).effectiveMaximumVolume, 22)
        XCTAssertEqual(records.volumePreferences(for: second.id).effectiveMaximumVolume, 100)
    }

    func testLegacySpeakerWithoutPreferencesRetainsFullRange() throws {
        let (records, id, _, _) = try fixture(volume: 30)
        let saved = try XCTUnwrap(records.speaker(id: id))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        json.removeValue(forKey: "volumePreferences")
        let decoded = try JSONDecoder().decode(SavedSpeaker.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.volumePreferences)
    }

    private func snapshot(volume: Int) -> SpeakerSnapshot {
        SpeakerSnapshot(status: .powerOn, source: .wifi, volume: volume, name: "Living", model: "LS60")
    }

    private func fixture(volume: Int) throws -> (SpeakerRecordStore, String, VolumeLimitClient, SpeakerCommandService) {
        let defaults = UserDefaults(suiteName: "VolumeLimitTests.\(UUID().uuidString)")!
        let records = SpeakerRecordStore(defaults: defaults)
        let state = snapshot(volume: volume)
        let id = try XCTUnwrap(records.save(host: "living.local", macAddress: nil, snapshot: state)).id
        let client = VolumeLimitClient(snapshot: state)
        return (records, id, client, SpeakerCommandService(speakerRecords: records, clientFactory: { _ in client }))
    }
}

private actor VolumeLimitClient: KEFSpeakerClient {
    nonisolated let host = "living.local"
    var snapshot: SpeakerSnapshot
    var writes: [Int] = []
    private var readGate: VolumeReadGate?
    func setReadGate(_ gate: VolumeReadGate) { readGate = gate }
    init(snapshot: SpeakerSnapshot) { self.snapshot = snapshot }
    func getSnapshot() async throws -> SpeakerSnapshot {
        await readGate?.enter()
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
    func setVolume(_ volume: Int) async throws { writes.append(volume); snapshot.volume = volume }
    func setSource(_ source: SpeakerSource) async throws { snapshot.source = source }
    func powerOn() async throws { snapshot.status = .powerOn }
    func shutdown() async throws { snapshot.status = .standby }
    func togglePlayPause() async throws {}
    func nextTrack() async throws {}
    func previousTrack() async throws {}
    func testConnection() async -> Bool { true }
}

private actor VolumeReadGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func enter() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
