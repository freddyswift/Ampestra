import Foundation
import KEFCore
import WidgetKit

/// Last known speaker state, distinct from the volume saved for unmuting.
struct WidgetSpeakerReading: Codable, Equatable, Sendable {
    let volume: Int
    let isPoweredOn: Bool
    let updatedAt: Date
}

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
    var widgetReading: WidgetSpeakerReading? = nil
    var volumePreferences: SpeakerVolumePreferences? = nil

    var connectionHosts: [String] {
        // Historical DHCP addresses are not proof of speaker identity.
        ManualHostValidator.normalizedHost(host).map { [$0] } ?? []
    }

    func accepts(_ snapshot: SpeakerSnapshot) -> Bool {
        requiresReconfirmation != true && hasSameIdentity(as: snapshot)
    }

    fileprivate func hasSameIdentity(as snapshot: SpeakerSnapshot) -> Bool {
        !model.isEmpty && displayName == Self.normalizedName(snapshot.name)
            && model == snapshot.model
    }

    var displayName: String {
        Self.normalizedName(name)
    }

    fileprivate static func normalizedName(_ name: String) -> String {
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
    private let reloadWidgets: @Sendable () -> Void

    init(
        defaults: UserDefaults = .standard,
        reloadWidgets: @escaping @Sendable () -> Void = {
            WidgetCenter.shared.reloadTimelines(ofKind: AmpestraWidgetConstants.controlsKind)
        }
    ) {
        self.defaults = defaults
        self.reloadWidgets = reloadWidgets
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

        let saved = lock.withLock {
            var records = loadRecordsLocked()
            let exactMACIndex = macAddress.flatMap { macAddress in
                records.firstIndex { $0.macAddress == macAddress }
            }
            let compatibleHostIndices = records.indices.filter { index in
                let record = records[index]
                if let macAddress, let previousMAC = record.macAddress, macAddress != previousMAC { return false }
                return record.host == host && (record.model.isEmpty || record.hasSameIdentity(as: snapshot))
            }
            let activeHostIndex = compatibleHostIndices.first { records[$0].requiresReconfirmation != true }
            // Prefer a known MAC, then the active record at this address. Only
            // restore an old identity without a MAC when the match is unique;
            // address reuse can leave several indistinguishable tombstones.
            let existingIndex = exactMACIndex ?? activeHostIndex
                ?? (compatibleHostIndices.count == 1 ? compatibleHostIndices.first : nil)

            // Keep old Shortcuts IDs, but prevent them following an address
            // explicitly confirmed as belonging to another speaker.
            for index in records.indices where index != existingIndex && records[index].host == host {
                records[index].requiresReconfirmation = true
            }

            let speakerName = SavedSpeaker.normalizedName(snapshot.name)
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

            if let index = records.firstIndex(where: { $0.id == record.id }) {
                records[index].widgetReading = WidgetSpeakerReading(
                    volume: VolumePolicy.clampedVolume(snapshot.volume),
                    isPoweredOn: snapshot.status == .powerOn, updatedAt: Date()
                )
            }
            persistLocked(records)
            if makeDefault {
                defaults.set(record.id, forKey: SpeakerPreferenceKeys.defaultSpeakerID)
            }
            return records.first { $0.id == record.id }
        }
        reloadWidgets()
        return saved
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
            record.name = SavedSpeaker.normalizedName(snapshot.name)
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
            let volume = VolumePolicy.clampedVolume(volume)
            guard records[index].lastAudibleVolume != volume else { return }
            records[index].lastAudibleVolume = volume
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
        reloadWidgets()
    }

    func updateWidgetReading(id: String, volume: Int, isPoweredOn: Bool, now: Date = Date()) {
        let shouldReload = lock.withLock {
            var records = loadRecordsLocked()
            guard let index = records.firstIndex(where: { $0.id == id }),
                  records[index].requiresReconfirmation != true else { return false }
            let previous = records[index].widgetReading
            let volume = VolumePolicy.clampedVolume(volume)
            // Avoid requesting a timeline reload for every identical foreground poll.
            guard previous?.volume != volume || previous?.isPoweredOn != isPoweredOn
                    || now.timeIntervalSince(previous?.updatedAt ?? .distantPast) >= 60 else { return false }
            records[index].widgetReading = WidgetSpeakerReading(
                volume: volume, isPoweredOn: isPoweredOn, updatedAt: now
            )
            persistLocked(records)
            return true
        }
        if shouldReload {
            reloadWidgets()
        }
    }

    func remove(id: String) {
        let removed = lock.withLock {
            var records = loadRecordsLocked()
            guard records.contains(where: { $0.id == id }) else { return false }
            records.removeAll { $0.id == id }
            persistLocked(records)
            if defaults.string(forKey: SpeakerPreferenceKeys.defaultSpeakerID) == id {
                if let replacement = records.first {
                    defaults.set(replacement.id, forKey: SpeakerPreferenceKeys.defaultSpeakerID)
                } else {
                    defaults.removeObject(forKey: SpeakerPreferenceKeys.defaultSpeakerID)
                }
            }
            return true
        }
        if removed { reloadWidgets() }
    }

    @discardableResult
    func setDefaultSpeaker(id: String) -> Bool {
        let result = lock.withLock { () -> (found: Bool, changed: Bool) in
            guard loadRecordsLocked().contains(where: { $0.id == id }) else { return (false, false) }
            guard defaults.string(forKey: SpeakerPreferenceKeys.defaultSpeakerID) != id else { return (true, false) }
            defaults.set(id, forKey: SpeakerPreferenceKeys.defaultSpeakerID)
            return (true, true)
        }
        if result.changed { reloadWidgets() }
        return result.found
    }

    func volumePreferences(for id: String) -> SpeakerVolumePreferences {
        speaker(id: id)?.volumePreferences ?? SpeakerVolumePreferences()
    }

    func updateVolumePreferences(_ preferences: SpeakerVolumePreferences, for id: String) {
        lock.withLock {
            var records = loadRecordsLocked()
            guard let index = records.firstIndex(where: { $0.id == id }),
                  (records[index].volumePreferences ?? SpeakerVolumePreferences()) != preferences else { return }
            records[index].volumePreferences = preferences
            persistLocked(records)
        }
        // Widgets do not render presets or the ceiling. Their actions read
        // current preferences at execution, so editing a name needs no reload.
    }

    func prefersSnappedVolumeSteps() -> Bool {
        lock.withLock { defaults.bool(forKey: SpeakerPreferenceKeys.snapVolumeSteps) }
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
