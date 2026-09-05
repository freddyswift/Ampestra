import Foundation
import KEFCore

/// Preferences belong to a speaker's discovered MAC when available, with a
/// local-address fallback for manually configured speakers.
@MainActor
final class SpeakerVolumePreferenceStore {
    private let defaults: UserDefaults
    private let key = "speakerVolumePreferences"
    private let ownersKey = "speakerVolumePreferenceHostOwners"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func preferences(host: String?, macAddress: String?) -> SpeakerVolumePreferences {
        guard let host = normalizedHost(host) else { return SpeakerVolumePreferences() }
        let records = load()
        let previousMAC = owners()[host]
        if let mac = normalizedMAC(macAddress) {
            let hostPreferences = previousMAC == nil || previousMAC == mac ? records["host:\(host)"] : nil
            let preferences = records["mac:\(mac)"] ?? hostPreferences ?? SpeakerVolumePreferences()
            // Retain a discovered identity after the next scan clears its live
            // results, including when this speaker has moved to a new address.
            if previousMAC != mac { save(preferences, host: host, macAddress: mac) }
            return preferences
        } else if let previousMAC, let preferences = records["mac:\(previousMAC)"] {
            return preferences
        }
        return records["host:\(host)"] ?? SpeakerVolumePreferences()
    }

    func save(_ preferences: SpeakerVolumePreferences, host: String?, macAddress: String?) {
        guard let host = normalizedHost(host) else { return }
        var records = load()
        records["host:\(host)"] = preferences
        if let mac = normalizedMAC(macAddress) {
            records["mac:\(mac)"] = preferences
            var owners = owners()
            owners[host] = mac
            defaults.set(owners, forKey: ownersKey)
        } else if let mac = owners()[host] {
            records["mac:\(mac)"] = preferences
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
    }

    private func load() -> [String: SpeakerVolumePreferences] {
        guard let data = defaults.data(forKey: key),
              let records = try? JSONDecoder().decode([String: SpeakerVolumePreferences].self, from: data) else {
            return [:]
        }
        return records
    }

    private func owners() -> [String: String] {
        defaults.dictionary(forKey: ownersKey) as? [String: String] ?? [:]
    }

    private func normalizedHost(_ host: String?) -> String? {
        host.flatMap(ManualHostValidator.normalizedHost)
    }

    private func normalizedMAC(_ mac: String?) -> String? {
        guard let mac, makeWakeOnLANMagicPacket(macAddress: mac) != nil else { return nil }
        return mac.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
    }
}
