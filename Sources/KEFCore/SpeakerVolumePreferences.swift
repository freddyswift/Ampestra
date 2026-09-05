import Foundation

public struct VolumePreset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var volume: Int

    public init(id: UUID = UUID(), name: String, volume: Int) {
        self.id = id
        self.name = name
        self.volume = VolumePolicy.clampedVolume(volume)
    }
}

/// A speaker's app-controlled volume ceiling and reusable listening levels.
/// The ceiling applies to commands, without masking louder readings from the speaker.
public struct SpeakerVolumePreferences: Codable, Equatable, Sendable {
    public var maximumVolume: Int?
    public var presets: [VolumePreset]

    public init(maximumVolume: Int? = nil, presets: [VolumePreset] = Self.defaultPresets) {
        self.maximumVolume = maximumVolume.map(VolumePolicy.clampedVolume)
        self.presets = presets
    }

    public static let defaultPresets = [
        VolumePreset(id: UUID(uuidString: "B33B1B2A-84E1-440A-80AB-E9737977A011")!, name: "Quiet", volume: 15),
        VolumePreset(id: UUID(uuidString: "B33B1B2A-84E1-440A-80AB-E9737977A012")!, name: "Listening", volume: 35),
    ]

    public var effectiveMaximumVolume: Int {
        VolumePolicy.clampedVolume(maximumVolume ?? 100)
    }

    public func clampedVolume(_ volume: Int) -> Int {
        min(VolumePolicy.clampedVolume(volume), effectiveMaximumVolume)
    }
}
