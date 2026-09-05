import Foundation
import Network
import XCTest
@testable import AmpestraMobile
@testable import KEFCore

@MainActor
final class MobileBehaviorTests: XCTestCase {
    func testWidgetReadingPersistsZeroWithoutLosingMuteRestore() throws {
        let defaults = makeDefaults()
        let records = SpeakerRecordStore(defaults: defaults)
        let saved = try XCTUnwrap(records.save(host: "speaker.local", macAddress: nil,
                                               snapshot: speakerSnapshot(volume: 38)))
        let date = Date().addingTimeInterval(120)
        records.updateWidgetReading(id: saved.id, volume: 0, isPoweredOn: true, now: date)
        let reloaded = try XCTUnwrap(SpeakerRecordStore(defaults: defaults).defaultSpeaker())
        XCTAssertEqual(reloaded.widgetReading?.volume, 0)
        XCTAssertEqual(reloaded.widgetReading?.updatedAt, date)
        XCTAssertEqual(reloaded.lastAudibleVolume, 38)
        records.remove(id: saved.id)
        records.updateWidgetReading(id: saved.id, volume: 50, isPoweredOn: true)
        XCTAssertNil(records.defaultSpeaker())
    }

    func testWidgetReadingThrottlesIdenticalPollsButNotChanges() throws {
        let records = SpeakerRecordStore(defaults: makeDefaults())
        let saved = try XCTUnwrap(records.save(host: "speaker.local", macAddress: nil,
                                               snapshot: speakerSnapshot(volume: 38)))
        let date = try XCTUnwrap(saved.widgetReading?.updatedAt)
        records.updateWidgetReading(id: saved.id, volume: 38, isPoweredOn: true,
                                    now: date.addingTimeInterval(10))
        XCTAssertEqual(records.defaultSpeaker()?.widgetReading?.updatedAt, date)
        records.updateWidgetReading(id: saved.id, volume: 38, isPoweredOn: false,
                                    now: date.addingTimeInterval(11))
        XCTAssertEqual(records.defaultSpeaker()?.widgetReading?.isPoweredOn, false)
        records.updateWidgetReading(id: saved.id, volume: 38, isPoweredOn: false,
                                    now: date.addingTimeInterval(80))
        XCTAssertEqual(records.defaultSpeaker()?.widgetReading?.updatedAt, date.addingTimeInterval(80))
    }

    func testLegacySpeakerDoesNotInventWidgetVolumeFromRestoreValue() throws {
        let records = SpeakerRecordStore(defaults: makeDefaults())
        let saved = try XCTUnwrap(records.save(host: "speaker.local", macAddress: nil,
                                               snapshot: speakerSnapshot(volume: 38)))
        let data = try JSONEncoder().encode(saved)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "widgetReading")
        let legacy = try JSONDecoder().decode(SavedSpeaker.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.widgetReading)
        XCTAssertEqual(legacy.lastAudibleVolume, 38)
    }
    func testManualRefreshBurstSharesRequestWithPolling() async throws {
        let speaker = StubSpeaker(snapshots: [
            .success(speakerSnapshot()), .success(speakerSnapshot(volume: 50)),
        ])
        let store = RemoteStore(defaults: makeDefaults(), pollingInterval: .milliseconds(20),
                                clientFactory: { _ in speaker })
        store.hardwareButtonsEnabled = false
        defer { store.setAppActive(false) }
        store.setAppActive(true)
        store.connect(to: "speaker.local")
        try await waitUntil { store.connectionState == .connected }

        let gate = CommandGate()
        await speaker.setReadOperation { await gate.wait() }
        for _ in 0..<20 { store.refreshNow() }
        // Allow multiple polling intervals to elapse while the read is suspended.
        try await Task.sleep(for: .milliseconds(100))
        let attempts = await speaker.snapshotAttemptCount()
        await gate.resume()
        XCTAssertEqual(attempts, 2, "Connection plus one shared refresh")
        try await waitUntil { store.volume == 50 }
    }

    func testBackgroundingCancelsManualRefresh() async throws {
        let speaker = StubSpeaker(snapshots: [.success(speakerSnapshot())])
        let store = RemoteStore(defaults: makeDefaults(), pollingInterval: .seconds(60),
                                clientFactory: { _ in speaker })
        store.hardwareButtonsEnabled = false
        defer { store.setAppActive(false) }
        store.setAppActive(true)
        store.connect(to: "speaker.local")
        try await waitUntil { store.connectionState == .connected }

        let started = expectation(description: "Refresh started")
        let cancelled = expectation(description: "Refresh cancelled")
        await speaker.setReadOperation {
            started.fulfill()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                cancelled.fulfill()
                throw error
            }
        }
        store.refreshNow()
        await fulfillment(of: [started], timeout: 1)
        store.setAppActive(false)
        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertNil(store.lastError)
    }

    func testUnchangedSnapshotDoesNotPublishRemoteState() {
        let store = RemoteStore(defaults: makeDefaults())
        let snapshot = speakerSnapshot()
        store.apply(snapshot)
        var changes = 0
        let observation = store.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }

        store.apply(snapshot)
        XCTAssertEqual(changes, 0)
        var changed = snapshot
        changed.volume += 1
        store.apply(changed)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(store.volume, changed.volume)
    }

    func testStoppingInactiveHardwareCaptureDoesNotPublishChanges() {
        let controller = HardwareVolumeButtonController()
        var changes = 0
        let observation = controller.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        controller.stop()
        controller.stop()
        XCTAssertEqual(changes, 0)
    }

    func testConcurrentServicesPreserveBothVolumeAdjustments() async throws {
        let records = SpeakerRecordStore(defaults: makeDefaults())
        _ = records.save(host: "speaker.local", macAddress: nil, snapshot: speakerSnapshot())
        let speaker = StubSpeaker(snapshots: [.success(speakerSnapshot())])
        let first = SpeakerCommandService(speakerRecords: records) { _ in speaker }
        let second = SpeakerCommandService(speakerRecords: records) { _ in speaker }
        async let a = first.adjustVolume(by: 5)
        async let b = second.adjustVolume(by: 5)
        _ = try await (a, b)
        let volumes = await speaker.recordedVolumes()
        XCTAssertEqual(volumes, [40, 45])
    }

    func testForegroundAndIntentShareVolumeOrderingAndMuteRestore() async throws {
        let records = SpeakerRecordStore(defaults: makeDefaults())
        let speaker = StubSpeaker(snapshots: [.success(speakerSnapshot())])
        let store = RemoteStore(defaults: makeDefaults(), speakerRecords: records,
                                pollingInterval: .seconds(60), clientFactory: { _ in speaker })
        store.hardwareButtonsEnabled = false
        defer { store.setAppActive(false) }
        store.setAppActive(true)
        store.connect(to: "speaker.local")
        try await waitUntil { store.connectionState == .connected }
        let intentService = SpeakerCommandService(speakerRecords: records) { _ in speaker }
        store.adjustVolume(direction: 1)
        _ = try await intentService.adjustVolume(by: 5)
        try await waitUntil { !store.isAdjustingVolume }
        let beforeMute = await speaker.recordedVolumes()
        XCTAssertEqual(beforeMute, [40, 45])
        _ = try await intentService.setMuted(true)
        store.toggleMute()
        try await waitUntil { !store.isAdjustingVolume }
        let volumes = await speaker.recordedVolumes()
        XCTAssertEqual(volumes, [40, 45, 0, 45])
    }

    func testQueuedCommandCancellationDoesNotWriteOrBlockNextCommand() async throws {
        let records = SpeakerRecordStore(defaults: makeDefaults())
        _ = records.save(host: "speaker.local", macAddress: nil, snapshot: speakerSnapshot())
        let started = expectation(description: "First write started")
        let gate = CommandGate()
        let speaker = StubSpeaker(snapshots: [.success(speakerSnapshot())], writeOperation: {
            started.fulfill()
            await gate.wait()
        })
        let service = SpeakerCommandService(speakerRecords: records) { _ in speaker }
        let first = Task { try await service.setVolume(60) }
        await fulfillment(of: [started], timeout: 1)
        let cancelled = Task { try await service.setVolume(90) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        await gate.resume()
        _ = try await first.value
        let volumes = await speaker.recordedVolumes()
        XCTAssertEqual(volumes, [60])
        let status = try await service.status()
        XCTAssertEqual(status.volume, 60)
    }

    func testCommandDeadlineCancelsSlowRead() async throws {
        let records = SpeakerRecordStore(defaults: makeDefaults())
        _ = records.save(host: "speaker.local", macAddress: nil, snapshot: speakerSnapshot())
        let speaker = StubSpeaker(snapshots: [], readDelay: .seconds(60))
        let service = SpeakerCommandService(speakerRecords: records, clientFactory: { _ in speaker },
                                            timing: SpeakerCommandTimingPolicy(commandTimeout: .milliseconds(30)))
        let started = ContinuousClock.now
        do { _ = try await service.setVolume(90); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? SpeakerCommandError, .timedOut) }
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        let volumes = await speaker.recordedVolumes()
        XCTAssertTrue(volumes.isEmpty)
    }

    func testForgetRemovesOnlySelectedSpeakerAndRepairsDefault() async throws {
        let defaults = makeDefaults()
        let records = SpeakerRecordStore(defaults: defaults)
        let other = try XCTUnwrap(records.save(host: "other.local", macAddress: nil, snapshot: speakerSnapshot(name: "Office")))
        let selected = try XCTUnwrap(records.save(host: "selected.local", macAddress: nil, snapshot: speakerSnapshot()))
        let speaker = StubSpeaker(snapshots: [.success(speakerSnapshot())])
        let store = RemoteStore(defaults: defaults, speakerRecords: records, pollingInterval: .seconds(60), clientFactory: { _ in speaker })
        store.hardwareButtonsEnabled = false
        defer { store.setAppActive(false) }
        store.setAppActive(true)
        try await waitUntil { store.connectionState == .connected }
        store.disconnect(forget: true)
        XCTAssertNil(records.speaker(id: selected.id))
        XCTAssertEqual(records.allSpeakers().map(\.id), [other.id])
        XCTAssertEqual(records.defaultSpeaker()?.id, other.id)
    }

    func testDifferentMACAtSameAddressDoesNotStealShortcutIdentity() throws {
        let records = SpeakerRecordStore(defaults: makeDefaults())
        let original = try XCTUnwrap(records.save(host: "speaker.local", macAddress: "AA:BB:CC:DD:EE:FF", snapshot: speakerSnapshot()))
        let replacement = try XCTUnwrap(records.save(host: "speaker.local", macAddress: "11:22:33:44:55:66", snapshot: speakerSnapshot()))
        XCTAssertNotEqual(original.id, replacement.id)
        XCTAssertEqual(records.speaker(id: original.id)?.requiresReconfirmation, true)
        XCTAssertEqual(records.speaker(id: original.id)?.macAddress, original.macAddress)
    }

    func testChangedSpeakerIdentityRejectsCommandsBeforeWriting() async throws {
        let records = SpeakerRecordStore(defaults: makeDefaults())
        _ = records.save(host: "speaker.local", macAddress: nil, snapshot: speakerSnapshot())
        let replacement = StubSpeaker(snapshots: [.success(speakerSnapshot(name: "Different speaker"))])
        let service = SpeakerCommandService(speakerRecords: records) { _ in replacement }
        do { _ = try await service.setVolume(90); XCTFail("Expected identity mismatch") }
        catch { XCTAssertEqual(error as? SpeakerCommandError, .speakerIdentityChanged) }
        let volumes = await replacement.recordedVolumes()
        XCTAssertTrue(volumes.isEmpty)
    }

    func testChangingOrForgettingSpeakerDuringReadPreventsWrite() async throws {
        for forget in [false, true] {
            let records = SpeakerRecordStore(defaults: makeDefaults())
            let saved = try XCTUnwrap(records.save(host: "old.local", macAddress: "AA:BB:CC:DD:EE:FF", snapshot: speakerSnapshot()))
            let started = expectation(description: "Snapshot read started")
            let gate = CommandGate()
            let speaker = StubSpeaker(snapshots: [.success(speakerSnapshot())], readOperation: {
                started.fulfill()
                await gate.wait()
            })
            let service = SpeakerCommandService(speakerRecords: records) { _ in speaker }
            let command = Task { try await service.setVolume(90, speakerID: saved.id) }
            await fulfillment(of: [started], timeout: 1)
            if forget {
                records.remove(id: saved.id)
            } else {
                _ = records.save(host: "new.local", macAddress: saved.macAddress, snapshot: speakerSnapshot())
            }
            await gate.resume()
            do { _ = try await command.value; XCTFail("Changed target must not receive a write") }
            catch { XCTAssertEqual(error as? SpeakerCommandError, forget ? .speakerNotFound : .speakerIdentityChanged) }
            let volumes = await speaker.recordedVolumes()
            XCTAssertTrue(volumes.isEmpty)
        }
    }

    func testPollingDoesNotOverwriteSliderPreview() async throws {
        let speaker = StubSpeaker(snapshots: [.success(speakerSnapshot())])
        let store = RemoteStore(
            defaults: makeDefaults(), pollingInterval: .seconds(60),
            clientFactory: { _ in speaker }
        )
        store.hardwareButtonsEnabled = false
        defer { store.setAppActive(false) }
        store.setAppActive(true)
        store.connect(to: "speaker.local")
        try await waitUntil { store.connectionState == .connected }
        store.previewVolume(67)
        store.apply(speakerSnapshot(volume: 35))
        XCTAssertEqual(store.volume, 67)
        store.commitPreviewedVolume()
        try await waitUntil { !store.isAdjustingVolume }
        let volumes = await speaker.recordedVolumes()
        XCTAssertEqual(volumes, [67])
    }

    func testPowerCommandsRespectFirmwareAndSetupStates() async throws {
        for status in [SpeakerStatus.firmwareUpgrade, .networkSetup, .unknown("calibrating")] {
            let defaults = makeDefaults()
            _ = SpeakerRecordStore(defaults: defaults).save(host: "speaker.local", macAddress: nil, snapshot: speakerSnapshot(status: status))
            let speaker = StubSpeaker(snapshots: [.success(speakerSnapshot(status: status))])
            let service = SpeakerCommandService(defaults: defaults) { _ in speaker }
            do {
                _ = try await service.setPower(on: true)
                XCTFail("Expected power controls to be unavailable")
            } catch {
                XCTAssertEqual(error as? SpeakerCommandError, .powerUnavailable)
            }
            let commands = await speaker.recordedPowerCommands()
            XCTAssertTrue(commands.isEmpty)
        }
    }

    func testCancelledVolumeWriteDoesNotReportLateFailure() async throws {
        let started = expectation(description: "Volume write started")
        let finished = expectation(description: "Old write returned")
        let gate = CommandGate()
        let speaker = StubSpeaker(snapshots: [.success(speakerSnapshot())], writeOperation: {
            started.fulfill()
            await gate.wait()
            finished.fulfill()
            throw URLError(.cancelled)
        })
        let store = RemoteStore(defaults: makeDefaults(), pollingInterval: .seconds(60), clientFactory: { _ in speaker })
        store.hardwareButtonsEnabled = false
        defer { store.setAppActive(false) }
        store.setAppActive(true)
        store.connect(to: "speaker.local")
        try await waitUntil { store.connectionState == .connected }
        store.setVolume(40)
        await fulfillment(of: [started], timeout: 1)
        store.disconnect()
        await gate.resume()
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertNil(store.lastError)
        XCTAssertFalse(store.isAdjustingVolume)
        XCTAssertEqual(store.connectionState, .disconnected)
    }

    func testLateCommandFailureDoesNotDisconnectNewSpeaker() async throws {
        let started = expectation(description: "Source command started")
        let finished = expectation(description: "Old command returned")
        let gate = CommandGate()
        let old = StubSpeaker(snapshots: [.success(speakerSnapshot())], writeOperation: {
            started.fulfill()
            await gate.wait()
            finished.fulfill()
            throw URLError(.networkConnectionLost)
        })
        let new = StubSpeaker(snapshots: [.success(speakerSnapshot(name: "Office"))])
        let store = RemoteStore(
            defaults: makeDefaults(), pollingInterval: .seconds(60),
            clientFactory: { $0 == "old.local" ? old : new }
        )
        store.hardwareButtonsEnabled = false
        defer { store.setAppActive(false) }
        store.setAppActive(true)
        store.connect(to: "old.local")
        try await waitUntil { store.connectionState == .connected }
        store.setSource(.tv)
        await fulfillment(of: [started], timeout: 1)
        store.connect(to: "new.local")
        try await waitUntil { store.speakerName == "Office" }
        XCTAssertFalse(store.isSendingCommand)
        await gate.resume()
        await fulfillment(of: [finished], timeout: 1)
        // Let the cancelled worker handle the error before inspecting state.
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(store.connectionState, .connected)
        XCTAssertEqual(store.currentHost, "new.local")
        XCTAssertNil(store.lastError)
    }

    func testSpeakerCommandServiceBoundsExtremeAdjustments() async throws {
        let defaults = makeDefaults()
        _ = SpeakerRecordStore(defaults: defaults).save(host: "speaker.local", macAddress: nil, snapshot: speakerSnapshot())
        let speaker = StubSpeaker(snapshots: [
            .success(speakerSnapshot(volume: 35)), .success(speakerSnapshot(volume: 35))
        ])
        let service = SpeakerCommandService(defaults: defaults) { _ in speaker }
        let raised = try await service.adjustVolume(by: Int.max)
        let lowered = try await service.adjustVolume(by: Int.min)
        XCTAssertEqual(raised.volume, 100)
        XCTAssertEqual(lowered.volume, 0)
    }

    func testCancelledNetworkReadDoesNotRetryOrWakeSpeaker() async throws {
        let records = SpeakerRecordStore(defaults: makeDefaults())
        _ = records.save(host: "speaker.local", macAddress: "AA:BB:CC:DD:EE:FF", snapshot: speakerSnapshot())
        let speaker = StubSpeaker(snapshots: [.failure(.cancelled)])
        let wakeRecorder = WakeRecorder()
        let service = SpeakerCommandService(
            speakerRecords: records, clientFactory: { _ in speaker },
            sleep: { _ in }, wakeSender: { wakeRecorder.record($0); return true }
        )
        do {
            _ = try await service.setPower(on: true)
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // URLSession cancellation must retain its meaning through the service.
        }
        let reads = await speaker.snapshotReadCount()
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(wakeRecorder.addresses.isEmpty)
    }

    func testOutputVolumeInterpreterInfersBothDirections() {
        var interpreter = OutputVolumeChangeInterpreter(initialVolume: 0.5)

        XCTAssertEqual(interpreter.direction(for: 0.5625), .up)
        XCTAssertEqual(interpreter.direction(for: 0.5), .down)
        XCTAssertNil(interpreter.direction(for: 0.5))
    }

    func testOutputVolumeLimitsRequestRecentering() {
        XCTAssertTrue(OutputVolumeChangeInterpreter.shouldRecenter(0))
        XCTAssertTrue(OutputVolumeChangeInterpreter.shouldRecenter(1))
        XCTAssertTrue(OutputVolumeChangeInterpreter.shouldRecenter(0.24))
        XCTAssertTrue(OutputVolumeChangeInterpreter.shouldRecenter(0.76))
        XCTAssertFalse(OutputVolumeChangeInterpreter.shouldRecenter(0.5))

        var atMinimum = OutputVolumeChangeInterpreter(initialVolume: 0)
        XCTAssertEqual(atMinimum.direction(for: 0.0625), .up)

        var atMaximum = OutputVolumeChangeInterpreter(initialVolume: 1)
        XCTAssertEqual(atMaximum.direction(for: 0.9375), .down)
    }

    func testVolumeHapticsDetectLandmarksEvenAcrossFastDrags() {
        XCTAssertTrue(VolumeHapticPolicy.crossesLandmark(from: 49, to: 51))
        XCTAssertTrue(VolumeHapticPolicy.crossesLandmark(from: 51, to: 49))
        XCTAssertTrue(VolumeHapticPolicy.crossesLandmark(from: 3, to: 0))
        XCTAssertTrue(VolumeHapticPolicy.crossesLandmark(from: 98, to: 100))
        XCTAssertFalse(VolumeHapticPolicy.crossesLandmark(from: 40, to: 42))
        XCTAssertFalse(VolumeHapticPolicy.crossesLandmark(from: 50, to: 51))
    }

    func testRapidAbsoluteAndRelativeVolumeCommandsPreserveTapOrder() async throws {
        let speaker = StubSpeaker(snapshots: [.success(speakerSnapshot())])
        let store = RemoteStore(defaults: makeDefaults(), pollingInterval: .seconds(60), clientFactory: { _ in speaker })
        store.hardwareButtonsEnabled = false
        defer { store.setAppActive(false) }
        store.setAppActive(true)
        store.connect(to: "speaker.local")
        try await waitUntil { store.connectionState == .connected }
        store.setVolume(20)
        store.adjustVolume(direction: 1)
        store.setVolume(60)
        store.adjustVolume(direction: -1)
        try await waitUntil { !store.isAdjustingVolume }
        let volumes = await speaker.recordedVolumes()
        XCTAssertEqual(volumes, [20, 25, 60, 55])
        XCTAssertEqual(store.volume, 55)
    }

    func testReconnectPolicyBacksOffAndCaps() {
        let policy = ReconnectPolicy(delays: [.seconds(1), .seconds(2), .seconds(5)])

        XCTAssertEqual(policy.delay(afterFailure: 1), .seconds(1))
        XCTAssertEqual(policy.delay(afterFailure: 2), .seconds(2))
        XCTAssertEqual(policy.delay(afterFailure: 3), .seconds(5))
        XCTAssertEqual(policy.delay(afterFailure: 20), .seconds(5))
    }

    func testStoreRecoversAfterSpeakerDisconnect() async throws {
        let poweredOn = SpeakerSnapshot(
            status: .powerOn,
            source: .wifi,
            volume: 44,
            name: "Office",
            model: "LSXII"
        )
        let speaker = StubSpeaker(snapshots: [
            .success(poweredOn),
            .failure(.unreachable),
            .success(poweredOn),
        ])
        let defaults = makeDefaults()
        let store = RemoteStore(
            defaults: defaults,
            reconnectPolicy: ReconnectPolicy(delays: [.seconds(60)]),
            pollingInterval: .milliseconds(100),
            clientFactory: { _ in speaker }
        )

        store.setAppActive(true)
        store.connect(to: "192.168.1.40")
        try await waitUntil { store.connectionState == .connected }
        try await waitUntil {
            if case .reconnecting = store.connectionState { return true }
            return false
        }

        store.refreshNow()
        try await waitUntil { store.connectionState == .connected }

        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.volume, 44)
        store.setAppActive(false)
    }

    func testStandbyIsConnectedButDisablesVolumeControls() async throws {
        let standby = SpeakerSnapshot(
            status: .standby,
            source: .wifi,
            volume: 18,
            name: "Bedroom",
            model: "LS50WII"
        )
        let speaker = StubSpeaker(snapshots: [.success(standby)])
        let store = RemoteStore(
            defaults: makeDefaults(),
            pollingInterval: .seconds(60),
            clientFactory: { _ in speaker }
        )

        store.setAppActive(true)
        store.connect(to: "192.168.1.41")
        try await waitUntil { store.connectionState == .connected }

        XCTAssertEqual(store.speakerStatus, .standby)
        XCTAssertFalse(store.canControlSpeaker)
        XCTAssertFalse(store.hardwareButtons.isCapturing)
        store.setAppActive(false)
    }

    func testStorePublishesNowPlayingMetadataForNetworkPlayback() async throws {
        let snapshot = SpeakerSnapshot(
            status: .powerOn,
            source: .wifi,
            volume: 36,
            name: "Living Room",
            model: "LS60"
        )
        let speaker = StubSpeaker(
            snapshots: [.success(snapshot)],
            playerState: PlayerState(
                isPlaying: true,
                nowPlaying: NowPlayingInfo(
                    title: "  Night Drive  ",
                    artist: "The Speakers",
                    album: "Living Room Sessions"
                )
            )
        )
        let store = RemoteStore(
            defaults: makeDefaults(),
            pollingInterval: .seconds(60),
            clientFactory: { _ in speaker }
        )

        store.setAppActive(true)
        store.connect(to: "192.168.1.42")
        try await waitUntil { store.nowPlaying?.title == "Night Drive" }

        XCTAssertTrue(store.isPlaying)
        XCTAssertEqual(store.nowPlaying?.artist, "The Speakers")
        XCTAssertEqual(store.nowPlaying?.album, "Living Room Sessions")
        store.setAppActive(false)
    }

    func testStoreClearsNowPlayingForSourcesWithoutMetadata() async throws {
        let wifi = SpeakerSnapshot(
            status: .powerOn,
            source: .wifi,
            volume: 36,
            name: "Living Room",
            model: "LS60"
        )
        let tv = SpeakerSnapshot(
            status: .powerOn,
            source: .tv,
            volume: 36,
            name: "Living Room",
            model: "LS60"
        )
        let speaker = StubSpeaker(
            snapshots: [.success(wifi), .success(tv)],
            playerState: PlayerState(
                isPlaying: true,
                nowPlaying: NowPlayingInfo(title: "Night Drive", artist: "The Speakers")
            )
        )
        let store = RemoteStore(
            defaults: makeDefaults(),
            pollingInterval: .seconds(60),
            clientFactory: { _ in speaker }
        )

        store.setAppActive(true)
        store.connect(to: "192.168.1.42")
        try await waitUntil { store.nowPlaying != nil }

        store.refreshNow()
        try await waitUntil { store.source == .tv }

        XCTAssertNil(store.nowPlaying)
        XCTAssertFalse(store.isPlaying)
        store.setAppActive(false)
    }

    func testStoreSendsPlaybackTransportCommands() async throws {
        let snapshot = SpeakerSnapshot(
            status: .powerOn,
            source: .wifi,
            volume: 36,
            name: "Living Room",
            model: "LS60"
        )
        let speaker = StubSpeaker(
            snapshots: [.success(snapshot)],
            playerState: PlayerState(
                isPlaying: true,
                nowPlaying: NowPlayingInfo(title: "Night Drive", artist: "The Speakers")
            )
        )
        let store = RemoteStore(
            defaults: makeDefaults(),
            pollingInterval: .seconds(60),
            clientFactory: { _ in speaker }
        )

        store.setAppActive(true)
        store.connect(to: "192.168.1.42")
        try await waitUntil { store.nowPlaying != nil }

        store.previousTrack()
        try await waitUntil { !store.isSendingCommand }
        store.togglePlayPause()
        try await waitUntil { !store.isSendingCommand }
        store.nextTrack()
        try await waitUntil { !store.isSendingCommand }

        let commands = await speaker.recordedPlaybackCommands()
        XCTAssertEqual(commands, ["previous", "playPause", "next"])
        store.setAppActive(false)
    }

    func testMutePhoneOnExitPreferencePersists() {
        let defaults = makeDefaults()
        let store = RemoteStore(defaults: defaults)

        XCTAssertFalse(store.mutePhoneOnExit)
        store.mutePhoneOnExit = true

        XCTAssertTrue(defaults.bool(forKey: SpeakerPreferenceKeys.mutePhoneOnExit))
    }

    func testSharedDefaultsMigrationPreservesExistingSharedPreferences() {
        let source = makeDefaults()
        let destination = makeDefaults()
        source.set("192.168.1.60", forKey: SpeakerPreferenceKeys.savedHost)
        source.set(7, forKey: SpeakerPreferenceKeys.volumeStep)
        source.set(true, forKey: SpeakerPreferenceKeys.hardwareButtonsEnabled)
        destination.set(9, forKey: SpeakerPreferenceKeys.volumeStep)

        AmpestraSharedDefaults.migrateFromStandardDefaultsIfNeeded(
            from: source,
            to: destination
        )

        XCTAssertEqual(
            destination.string(forKey: SpeakerPreferenceKeys.savedHost),
            "192.168.1.60"
        )
        XCTAssertEqual(destination.integer(forKey: SpeakerPreferenceKeys.volumeStep), 9)
        XCTAssertTrue(destination.bool(forKey: SpeakerPreferenceKeys.hardwareButtonsEnabled))
        XCTAssertTrue(destination.bool(forKey: AmpestraSharedDefaults.migrationKey))
    }

    func testPermissionDenialProducesActionableState() {
        let store = RemoteStore(defaults: makeDefaults())

        store.handleLocalNetworkPermissionDenied()

        XCTAssertTrue(store.localNetworkPermissionDenied)
        XCTAssertEqual(store.connectionState, .failed(message: "Local Network access is off"))
        XCTAssertTrue(store.lastError?.contains("Settings") == true)
    }

    func testSpeakerCommandServiceAdjustsVolumeByFive() async throws {
        let snapshot = SpeakerSnapshot(
            status: .powerOn,
            source: .wifi,
            volume: 42,
            name: "Living Room",
            model: "LS60"
        )
        let speaker = StubSpeaker(snapshots: [.success(snapshot)])
        let defaults = makeDefaults()
        _ = SpeakerRecordStore(defaults: defaults).save(host: speaker.host, macAddress: nil, snapshot: snapshot)
        let service = SpeakerCommandService(defaults: defaults) { _ in speaker }

        let confirmation = try await service.adjustVolume(by: 5)

        XCTAssertEqual(String(localized: confirmation.message), "Living Room volume is 47.")
        let volumes = await speaker.recordedVolumes()
        XCTAssertEqual(volumes, [47])
    }

    func testSpeakerCommandServiceChangesSource() async throws {
        let snapshot = SpeakerSnapshot(
            status: .powerOn,
            source: .wifi,
            volume: 35,
            name: "Office",
            model: "LSXII"
        )
        let speaker = StubSpeaker(snapshots: [.success(snapshot)])
        let defaults = makeDefaults()
        _ = SpeakerRecordStore(defaults: defaults).save(host: speaker.host, macAddress: nil, snapshot: snapshot)
        let service = SpeakerCommandService(defaults: defaults) { _ in speaker }

        let confirmation = try await service.setSource(.tv)

        XCTAssertEqual(String(localized: confirmation.message), "Office is set to TV.")
        let sources = await speaker.recordedSources()
        XCTAssertEqual(sources, [.tv])
    }

    func testSpeakerCommandServiceRequiresConfiguredSpeaker() async {
        let service = SpeakerCommandService(defaults: makeDefaults())

        do {
            _ = try await service.setVolume(30)
            XCTFail("Expected a missing-speaker error")
        } catch {
            XCTAssertEqual(error as? SpeakerCommandError, .noConfiguredSpeaker)
        }
    }

    func testSpeakerCommandServicePowersOnSpeakerInStandby() async throws {
        let snapshot = SpeakerSnapshot(
            status: .standby,
            source: .wifi,
            volume: 20,
            name: "Bedroom",
            model: "LS50WII"
        )
        let speaker = StubSpeaker(snapshots: [.success(snapshot)])
        let defaults = makeDefaults()
        _ = SpeakerRecordStore(defaults: defaults).save(host: speaker.host, macAddress: nil, snapshot: snapshot)
        let service = SpeakerCommandService(defaults: defaults) { _ in speaker }

        let confirmation = try await service.setPower(on: true)

        XCTAssertEqual(String(localized: confirmation.message), "Bedroom is on.")
        let powerCommands = await speaker.recordedPowerCommands()
        XCTAssertEqual(powerCommands, [true])
    }

    func testSavedSpeakerMigrationCreatesStableIdentity() {
        let defaults = makeDefaults()
        defaults.set("192.168.1.60", forKey: SpeakerPreferenceKeys.savedHost)
        defaults.set("aabbccddeeff", forKey: SpeakerPreferenceKeys.savedMACAddress)

        let firstStore = SpeakerRecordStore(defaults: defaults)
        let firstRecord = firstStore.defaultSpeaker()
        let reloadedRecord = SpeakerRecordStore(defaults: defaults).defaultSpeaker()

        XCTAssertNotNil(defaults.data(forKey: SpeakerPreferenceKeys.savedSpeakers))
        XCTAssertEqual(firstRecord?.id, reloadedRecord?.id)
        XCTAssertEqual(firstRecord?.host, "192.168.1.60")
        XCTAssertEqual(firstRecord?.macAddress, "AA:BB:CC:DD:EE:FF")
        XCTAssertNil(defaults.object(forKey: SpeakerPreferenceKeys.savedHost))
        XCTAssertNil(defaults.object(forKey: SpeakerPreferenceKeys.savedMACAddress))
    }

    func testSavedSpeakerKeepsIdentityWhenAddressChanges() throws {
        let records = SpeakerRecordStore(defaults: makeDefaults())
        let first = try XCTUnwrap(
            records.save(
                host: "192.168.1.60",
                macAddress: "AA:BB:CC:DD:EE:FF",
                snapshot: speakerSnapshot(name: "Living Room")
            )
        )
        let moved = try XCTUnwrap(
            records.save(
                host: "living-room.local",
                macAddress: "aa-bb-cc-dd-ee-ff",
                snapshot: speakerSnapshot(name: "Living Room")
            )
        )

        XCTAssertEqual(moved.id, first.id)
        XCTAssertEqual(moved.host, "living-room.local")
        XCTAssertEqual(moved.alternateHosts, [])
        XCTAssertEqual(records.allSpeakers().count, 1)
    }

    func testSavingNonDefaultSpeakerDoesNotChangeDefault() throws {
        let records = SpeakerRecordStore(defaults: makeDefaults())
        let defaultRecord = try XCTUnwrap(
            records.save(
                host: "192.168.1.60",
                macAddress: "AA:BB:CC:DD:EE:FF",
                snapshot: speakerSnapshot(name: "Living Room")
            )
        )
        _ = records.save(
            host: "192.168.1.61",
            macAddress: "11:22:33:44:55:66",
            snapshot: speakerSnapshot(name: "Office"),
            makeDefault: false
        )

        XCTAssertEqual(records.defaultSpeaker()?.id, defaultRecord.id)
    }

    func testSpeakerEntityUsesSavedStableIdentity() throws {
        let records = SpeakerRecordStore(defaults: makeDefaults())
        let record = try XCTUnwrap(
            records.save(
                host: "192.168.1.60",
                macAddress: nil,
                snapshot: speakerSnapshot(name: "Kitchen", model: "LSXII")
            )
        )

        let entity = SpeakerEntity(record: record)

        XCTAssertEqual(entity.id, record.id)
        XCTAssertEqual(entity.name, "Kitchen")
        XCTAssertEqual(entity.model, "LSXII")
    }

    func testSpeakerCommandServiceUsesConfiguredVolumeStep() async throws {
        let defaults = makeDefaults()
        defaults.set(7, forKey: SpeakerPreferenceKeys.volumeStep)
        let records = SpeakerRecordStore(defaults: defaults)
        let snapshot = speakerSnapshot(volume: 42)
        _ = records.save(host: "192.168.1.60", macAddress: nil, snapshot: snapshot)
        let speaker = StubSpeaker(snapshots: [.success(snapshot)])
        let service = SpeakerCommandService(speakerRecords: records) { _ in speaker }

        let confirmation = try await service.adjustVolume(direction: 1)
        let volumes = await speaker.recordedVolumes()

        XCTAssertEqual(confirmation.volume, 49)
        XCTAssertEqual(volumes, [49])
        XCTAssertEqual(records.defaultSpeaker()?.widgetReading?.volume, 49)
    }

    func testSpeakerCommandServiceRestoresLastAudibleVolume() async throws {
        let records = SpeakerRecordStore(defaults: makeDefaults())
        _ = records.save(
            host: "192.168.1.60",
            macAddress: nil,
            snapshot: speakerSnapshot(volume: 38)
        )
        let mutedSnapshot = speakerSnapshot(volume: 0)
        let speaker = StubSpeaker(snapshots: [.success(mutedSnapshot)])
        let service = SpeakerCommandService(speakerRecords: records) { _ in speaker }

        let confirmation = try await service.setMuted(false)
        let volumes = await speaker.recordedVolumes()

        XCTAssertEqual(confirmation.volume, 38)
        XCTAssertEqual(volumes, [38])
    }

    func testSpeakerCommandServiceRetriesTransientRead() async throws {
        let records = SpeakerRecordStore(defaults: makeDefaults())
        let snapshot = speakerSnapshot()
        _ = records.save(host: "192.168.1.60", macAddress: nil, snapshot: snapshot)
        let speaker = StubSpeaker(snapshots: [.failure(.unreachable), .success(snapshot)])
        let timing = SpeakerCommandTimingPolicy(
            readAttempts: 2,
            readRetryDelay: .zero,
            wakePollingDelays: []
        )
        let service = SpeakerCommandService(
            speakerRecords: records,
            clientFactory: { _ in speaker },
            timing: timing,
            sleep: { _ in }
        )

        let confirmation = try await service.status()
        let readCount = await speaker.snapshotReadCount()

        XCTAssertEqual(confirmation.speakerName, "Living Room")
        XCTAssertEqual(readCount, 2)
    }

    func testSpeakerCommandServiceDoesNotContactHistoricalAddress() async throws {
        let defaults = makeDefaults()
        let records = SpeakerRecordStore(defaults: defaults)
        let snapshot = speakerSnapshot()
        var first = try XCTUnwrap(records.save(host: "living-room.local", macAddress: "AA:BB:CC:DD:EE:FF", snapshot: snapshot))
        // Exercise records persisted by older builds, including a stale DHCP IP.
        first.alternateHosts = ["192.168.1.60"]
        defaults.set(try JSONEncoder().encode([first]), forKey: SpeakerPreferenceKeys.savedSpeakers)
        let unavailable = StubSpeaker(snapshots: [.failure(.unreachable)])
        let reachable = StubSpeaker(snapshots: [.success(snapshot)])
        let timing = SpeakerCommandTimingPolicy(
            readAttempts: 1,
            readRetryDelay: .zero,
            wakePollingDelays: []
        )
        let service = SpeakerCommandService(
            speakerRecords: records,
            clientFactory: { host in
                host == "living-room.local" ? unavailable : reachable
            },
            timing: timing,
            sleep: { _ in }
        )

        do {
            _ = try await service.status(speakerID: first.id)
            XCTFail("Historical addresses must not be used automatically")
        } catch {
            XCTAssertEqual(error as? SpeakerCommandError, .unreachable)
        }
        let unavailableReads = await unavailable.snapshotReadCount()
        let reachableReads = await reachable.snapshotReadCount()

        XCTAssertEqual(records.speaker(id: first.id)?.host, "living-room.local")
        XCTAssertEqual(unavailableReads, 1)
        XCTAssertEqual(reachableReads, 0)
    }

    func testSpeakerCommandServiceUsesWakeOnLANWhenSpeakerIsOffline() async throws {
        let records = SpeakerRecordStore(defaults: makeDefaults())
        let snapshot = speakerSnapshot(status: .standby)
        _ = records.save(
            host: "192.168.1.60",
            macAddress: "AA:BB:CC:DD:EE:FF",
            snapshot: snapshot
        )
        let speaker = StubSpeaker(snapshots: [.failure(.unreachable), .success(snapshot)])
        let wakeRecorder = WakeRecorder()
        let timing = SpeakerCommandTimingPolicy(
            readAttempts: 1,
            readRetryDelay: .zero,
            wakePollingDelays: [.zero]
        )
        let service = SpeakerCommandService(
            speakerRecords: records,
            clientFactory: { _ in speaker },
            timing: timing,
            sleep: { _ in },
            wakeSender: { macAddress in
                wakeRecorder.record(macAddress)
                return true
            }
        )

        let confirmation = try await service.setPower(on: true)
        let powerCommands = await speaker.recordedPowerCommands()

        XCTAssertEqual(wakeRecorder.addresses, ["AA:BB:CC:DD:EE:FF"])
        XCTAssertEqual(powerCommands, [true])
        XCTAssertTrue(confirmation.changed)
        XCTAssertEqual(confirmation.status, .powerOn)
    }

    func testSpeakerCommandServiceDoesNotRepeatSatisfiedPowerCommand() async throws {
        let records = SpeakerRecordStore(defaults: makeDefaults())
        let snapshot = speakerSnapshot(status: .powerOn)
        _ = records.save(host: "192.168.1.60", macAddress: nil, snapshot: snapshot)
        let speaker = StubSpeaker(snapshots: [.success(snapshot)])
        let service = SpeakerCommandService(speakerRecords: records) { _ in speaker }

        let confirmation = try await service.setPower(on: true)
        let powerCommands = await speaker.recordedPowerCommands()

        XCTAssertFalse(confirmation.changed)
        XCTAssertEqual(powerCommands, [])
    }

    func testSpeakerCommandServiceReportsMissingWakeAddress() async throws {
        let records = SpeakerRecordStore(defaults: makeDefaults())
        let snapshot = speakerSnapshot(status: .standby)
        _ = records.save(host: "192.168.1.60", macAddress: nil, snapshot: snapshot)
        let speaker = StubSpeaker(snapshots: [.failure(.unreachable)])
        let timing = SpeakerCommandTimingPolicy(
            readAttempts: 1,
            readRetryDelay: .zero,
            wakePollingDelays: [.zero]
        )
        let service = SpeakerCommandService(
            speakerRecords: records,
            clientFactory: { _ in speaker },
            timing: timing,
            sleep: { _ in }
        )

        do {
            _ = try await service.setPower(on: true)
            XCTFail("Expected a missing hardware-address error")
        } catch {
            XCTAssertEqual(error as? SpeakerCommandError, .wakeUnavailable)
        }
    }

    func testBonjourPolicyDenialIsRecognized() {
        XCTAssertTrue(
            KEFDiscovery.isLocalNetworkPolicyDenied(
                .dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))
            )
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "MobileBehaviorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func speakerSnapshot(
        status: SpeakerStatus = .powerOn,
        source: SpeakerSource = .wifi,
        volume: Int = 35,
        name: String = "Living Room",
        model: String = "LS60"
    ) -> SpeakerSnapshot {
        SpeakerSnapshot(
            status: status,
            source: source,
            volume: volume,
            name: name,
            model: model
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition was not met before timeout")
    }
}

private actor StubSpeaker: KEFSpeakerClient {
    enum StubFailure: Error {
        case unreachable
        case cancelled
    }

    enum SnapshotResult {
        case success(SpeakerSnapshot)
        case failure(StubFailure)
    }

    nonisolated let host: String
    private var snapshots: [SnapshotResult]
    private var snapshotAttempts = 0
    private var snapshotReads = 0
    private var lastSnapshot = SpeakerSnapshot(status: .powerOn, source: .wifi, volume: 30, name: "Test", model: "LS60")
    private let playerState: PlayerState
    private var volumes: [Int] = []
    private var sources: [SpeakerSource] = []
    private var powerCommands: [Bool] = []
    private var playbackCommands: [String] = []
    private let readDelay: Duration
    private var readOperation: (@Sendable () async throws -> Void)?
    private let writeOperation: (@Sendable () async throws -> Void)?

    init(
        host: String = "192.168.1.99",
        snapshots: [SnapshotResult],
        playerState: PlayerState = PlayerState(isPlaying: false, nowPlaying: NowPlayingInfo()),
        writeOperation: (@Sendable () async throws -> Void)? = nil,
        readDelay: Duration = .zero,
        readOperation: (@Sendable () async throws -> Void)? = nil
    ) {
        self.host = host
        self.snapshots = snapshots
        self.playerState = playerState
        self.writeOperation = writeOperation
        self.readDelay = readDelay
        self.readOperation = readOperation
    }

    func setReadOperation(_ operation: @escaping @Sendable () async throws -> Void) {
        readOperation = operation
    }

    func snapshotAttemptCount() -> Int { snapshotAttempts }

    func getSnapshot() async throws -> SpeakerSnapshot {
        snapshotAttempts += 1
        try await readOperation?()
        if readDelay != .zero { try await Task.sleep(for: readDelay) }
        snapshotReads += 1
        guard !snapshots.isEmpty else {
            return lastSnapshot
        }

        switch snapshots.removeFirst() {
        case .success(let snapshot):
            lastSnapshot = snapshot
            return snapshot
        case .failure(let error):
            if error == .cancelled { throw URLError(.cancelled) }
            throw error
        }
    }

    func getStatus() async throws -> SpeakerStatus { try await getSnapshot().status }
    func getSource() async throws -> SpeakerSource { try await getSnapshot().source }
    func getVolume() async throws -> Int { try await getSnapshot().volume }
    func getSpeakerName() async throws -> String { try await getSnapshot().name }
    func getModel() async throws -> String { try await getSnapshot().model }
    func getPlayerState() async throws -> PlayerState { playerState }
    func getIsPlaying() async throws -> Bool { playerState.isPlaying }
    func getNowPlayingInfo() async throws -> NowPlayingInfo { playerState.nowPlaying }

    func setVolume(_ volume: Int) async throws {
        try await writeOperation?()
        volumes.append(volume)
    }

    func setSource(_ source: SpeakerSource) async throws {
        try await writeOperation?()
        sources.append(source)
    }

    func powerOn() async throws {
        powerCommands.append(true)
    }

    func shutdown() async throws {
        powerCommands.append(false)
    }
    func togglePlayPause() async throws {
        playbackCommands.append("playPause")
    }

    func nextTrack() async throws {
        playbackCommands.append("next")
    }

    func previousTrack() async throws {
        playbackCommands.append("previous")
    }
    func validateConnection() async throws {}
    func testConnection() async -> Bool { true }

    func recordedVolumes() -> [Int] { volumes }
    func recordedSources() -> [SpeakerSource] { sources }
    func recordedPowerCommands() -> [Bool] { powerCommands }
    func recordedPlaybackCommands() -> [String] { playbackCommands }
    func snapshotReadCount() -> Int { snapshotReads }
}

private actor CommandGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var resumed = false

    func wait() async {
        if resumed { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func resume() {
        resumed = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

private final class WakeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedAddresses: [String] = []

    var addresses: [String] {
        lock.withLock { recordedAddresses }
    }

    func record(_ address: String) {
        lock.withLock {
            recordedAddresses.append(address)
        }
    }
}
