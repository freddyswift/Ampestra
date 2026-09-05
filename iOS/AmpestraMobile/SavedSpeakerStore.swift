import Foundation
import KEFCore

struct SavedSpeaker: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var model: String
    var host: String
    var alternateHosts: [String]
    var macAddress: String?
    var lastSeenAt: Date
    var lastAudibleVolume: Int?
    var requiresReconfirmation: Bool? = nil

    var connectionHosts: [String] {
        // Historical DHCP addresses are not proof of speaker identity.
        ManualHostValidator.normalizedHost(host).map { [$0] } ?? []
    }

    func accepts(_ snapshot: SpeakerSnapshot) -> Bool {
        guard requiresReconfirmation != true, !model.isEmpty else { return false }
        return name.trimmingCharacters(in: .whitespacesAndNewlines) == snapshot.name.trimmingCharacters(in: .whitespacesAndNewlines)
            && model == snapshot.model
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "KEF Speaker" : trimmed
    }
}

/// Thread-safe persistence shared by the foreground remote and App Intents.
/// Speaker IDs are generated once and remain stable even if DHCP changes the
/// address that the speaker uses.
final class SpeakerRecordStore: @unchecked Sendable {
    static let shared = SpeakerRecordStore(defaults: AmpestraSharedDefaults.shared)

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func allSpeakers() -> [SavedSpeaker] {
        lock.withLock { loadRecordsLocked() }
    }

    func defaultSpeaker() -> SavedSpeaker? {
        lock.withLock {
            let records = loadRecordsLocked()
            guard !records.isEmpty else { return nil }

            if let defaultID = defaults.string(forKey: SpeakerPreferenceKeys.defaultSpeakerID),
               let speaker = records.first(where: { $0.id == defaultID }) {
                return speaker
            }

            defaults.set(records[0].id, forKey: SpeakerPreferenceKeys.defaultSpeakerID)
            return records[0]
        }
    }

    func speaker(id: String) -> SavedSpeaker? {
        lock.withLock {
            loadRecordsLocked().first(where: { $0.id == id })
        }
    }

    @discardableResult
    func save(
        host rawHost: String,
        macAddress rawMACAddress: String?,
        snapshot: SpeakerSnapshot,
        makeDefault: Bool = true
    ) -> SavedSpeaker? {
        guard let host = ManualHostValidator.normalizedHost(rawHost) else { return nil }
        let macAddress = Self.normalizedMACAddress(rawMACAddress)

        return lock.withLock {
            var records = loadRecordsLocked()
            let existingIndex = records.firstIndex { record in
                if let macAddress, record.macAddress == macAddress { return true }
                if let macAddress, let previousMAC = record.macAddress, macAddress != previousMAC { return false }
                return record.host == host && (record.model.isEmpty || record.accepts(snapshot))
            }

            // Keep old Shortcuts IDs, but prevent them following an address
            // explicitly confirmed as belonging to another speaker.
            for index in records.indices where index != existingIndex && records[index].host == host {
                records[index].requiresReconfirmation = true
            }

            let speakerName = Self.normalizedSpeakerName(snapshot.name)
            let audibleVolume = snapshot.volume > 0
                ? VolumePolicy.clampedVolume(snapshot.volume)
                : existingIndex.flatMap { records[$0].lastAudibleVolume }

            let record: SavedSpeaker
            if let existingIndex {
                var existing = records[existingIndex]
                existing.name = speakerName
                existing.model = snapshot.model
                existing.host = host
                existing.alternateHosts = []
                existing.requiresReconfirmation = false
                existing.macAddress = macAddress ?? existing.macAddress
                existing.lastSeenAt = Date()
                existing.lastAudibleVolume = audibleVolume
                records[existingIndex] = existing
                record = existing
            } else {
                record = SavedSpeaker(
                    id: UUID().uuidString,
                    name: speakerName,
                    model: snapshot.model,
                    host: host,
                    alternateHosts: [],
                    macAddress: macAddress,
                    lastSeenAt: Date(),
                    lastAudibleVolume: audibleVolume
                )
                records.append(record)
            }

            persistLocked(records)
            if makeDefault {
                defaults.set(record.id, forKey: SpeakerPreferenceKeys.defaultSpeakerID)
            }
            return record
        }
    }

    func markReachable(
        id: String,
        host rawHost: String,
        snapshot: SpeakerSnapshot
    ) {
        guard let host = ManualHostValidator.normalizedHost(rawHost) else { return }

        lock.withLock {
            var records = loadRecordsLocked()
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }

            var record = records[index]
            guard record.host == host, record.accepts(snapshot) else { return }
            record.name = Self.normalizedSpeakerName(snapshot.name)
            record.model = snapshot.model
            record.host = host
            record.alternateHosts = []
            record.lastSeenAt = Date()
            if snapshot.volume > 0 {
                record.lastAudibleVolume = VolumePolicy.clampedVolume(snapshot.volume)
            }
            records[index] = record
            persistLocked(records)
        }
    }

    func rememberAudibleVolume(_ volume: Int, for id: String) {
        guard volume > 0 else { return }

        lock.withLock {
            var records = loadRecordsLocked()
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }
            records[index].lastAudibleVolume = VolumePolicy.clampedVolume(volume)
            persistLocked(records)
        }
    }

    func removeAll() {
        lock.withLock {
            defaults.removeObject(forKey: SpeakerPreferenceKeys.savedSpeakers)
            defaults.removeObject(forKey: SpeakerPreferenceKeys.defaultSpeakerID)
            defaults.removeObject(forKey: SpeakerPreferenceKeys.savedHost)
            defaults.removeObject(forKey: SpeakerPreferenceKeys.savedMACAddress)
        }
    }

    func remove(id: String) {
        lock.withLock {
            var records = loadRecordsLocked()
            guard records.contains(where: { $0.id == id }) else { return }
            records.removeAll { $0.id == id }
            persistLocked(records)
            if defaults.string(forKey: SpeakerPreferenceKeys.defaultSpeakerID) == id {
                if let replacement = records.first {
                    defaults.set(replacement.id, forKey: SpeakerPreferenceKeys.defaultSpeakerID)
                } else {
                    defaults.removeObject(forKey: SpeakerPreferenceKeys.defaultSpeakerID)
                }
            }
        }
    }

    func preferredVolumeStep() -> Int {
        lock.withLock {
            defaults.object(forKey: SpeakerPreferenceKeys.volumeStep) == nil
                ? 5
                : VolumePolicy.clampedStepSize(defaults.integer(forKey: SpeakerPreferenceKeys.volumeStep))
        }
    }

    private func loadRecordsLocked() -> [SavedSpeaker] {
        if let data = defaults.data(forKey: SpeakerPreferenceKeys.savedSpeakers),
           let records = try? JSONDecoder().decode([SavedSpeaker].self, from: data) {
            return records
        }

        guard let rawHost = defaults.string(forKey: SpeakerPreferenceKeys.savedHost),
              let host = ManualHostValidator.normalizedHost(rawHost) else {
            return []
        }

        let migrated = SavedSpeaker(
            id: UUID().uuidString,
            name: "KEF Speaker",
            model: "",
            host: host,
            alternateHosts: [],
            macAddress: Self.normalizedMACAddress(
                defaults.string(forKey: SpeakerPreferenceKeys.savedMACAddress)
            ),
            lastSeenAt: .distantPast,
            lastAudibleVolume: nil
        )
        persistLocked([migrated])
        defaults.set(migrated.id, forKey: SpeakerPreferenceKeys.defaultSpeakerID)
        defaults.removeObject(forKey: SpeakerPreferenceKeys.savedHost)
        defaults.removeObject(forKey: SpeakerPreferenceKeys.savedMACAddress)
        return [migrated]
    }

    private func persistLocked(_ records: [SavedSpeaker]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: SpeakerPreferenceKeys.savedSpeakers)
    }

    private static func normalizedSpeakerName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "KEF Speaker" : trimmed
    }

    private static func normalizedMACAddress(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let hex = rawValue
            .filter(\.isHexDigit)
            .uppercased()
        guard hex.count == 12 else { return nil }

        return stride(from: 0, to: 12, by: 2)
            .map { offset in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                let end = hex.index(start, offsetBy: 2)
                return String(hex[start..<end])
            }
            .joined(separator: ":")
    }
}
