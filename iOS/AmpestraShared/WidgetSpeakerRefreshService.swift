import Foundation
import KEFCore

struct WidgetSpeakerRefreshResult {
    let speakerID: String?
    let reading: WidgetSpeakerReading?
    let refreshFailed: Bool
}

/// Timeline reads are short and read-only. They must not trigger another
/// timeline reload or delay the widget after a completed control intent.
struct WidgetSpeakerRefreshService {
    static let recentReadingInterval: TimeInterval = 10
    static let refreshInterval: TimeInterval = 15 * 60

    private let records: SpeakerRecordStore
    private let commands: SpeakerCommandService

    init(records: SpeakerRecordStore = .shared, commands: SpeakerCommandService? = nil) {
        self.records = records
        self.commands = commands ?? SpeakerCommandService(
            speakerRecords: records,
            timing: SpeakerCommandTimingPolicy(commandTimeout: .seconds(4), readAttempts: 1)
        )
    }

    /// Retains the last known reading on failure, without writing shared defaults.
    /// Resolve through the configuration so a removed selection never falls
    /// back to controlling the default speaker.
    func refresh(
        configuration: SelectWidgetSpeakerIntent,
        force: Bool = false,
        now: Date = Date()
    ) async -> WidgetSpeakerRefreshResult {
        guard let speaker = configuration.selectedSpeaker(in: records),
              speaker.requiresReconfirmation != true else {
            return .init(speakerID: nil, reading: nil, refreshFailed: true)
        }
        if !force, let reading = speaker.widgetReading,
           (0..<Self.recentReadingInterval).contains(now.timeIntervalSince(reading.updatedAt)) {
            return .init(speakerID: speaker.id, reading: reading, refreshFailed: false)
        }
        let requestStartedAt = Date()
        do {
            let result = try await commands.status(speakerID: speaker.id, updateRecords: false)
            // A host-app action may have completed while the extension awaited
            // the network. Prefer its confirmation to this potentially stale read.
            let latest = records.speaker(id: speaker.id)?.widgetReading
            let reading = latest.flatMap { $0.updatedAt > requestStartedAt ? $0 : nil }
                ?? WidgetSpeakerReading(volume: result.volume, isPoweredOn: result.status == .powerOn,
                                        updatedAt: Date())
            return .init(speakerID: speaker.id, reading: reading, refreshFailed: false)
        } catch {
            return .init(speakerID: speaker.id, reading: records.speaker(id: speaker.id)?.widgetReading,
                         refreshFailed: true)
        }
    }
}
