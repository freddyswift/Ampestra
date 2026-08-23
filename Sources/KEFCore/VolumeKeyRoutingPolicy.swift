import Foundation

/// Decides whether a hardware volume event belongs to the KEF speaker or macOS.
///
/// Keeping this policy independent of the event tap makes per-source routing
/// deterministic and directly testable.
public struct VolumeKeyRoutingPolicy: Equatable, Sendable {
    public var mode: VolumeKeyRoutingMode
    public var speakerSources: Set<SpeakerSource>

    public init(mode: VolumeKeyRoutingMode, speakerSources: Set<SpeakerSource>) {
        self.mode = mode
        self.speakerSources = speakerSources
    }

    public var requiresMediaKeyAccess: Bool {
        switch mode {
        case .mac:
            false
        case .auto:
            !speakerSources.isEmpty
        case .speaker:
            true
        }
    }

    public func routesToSpeaker(
        isConnected: Bool,
        status: SpeakerStatus,
        source: SpeakerSource,
        isPlaying: Bool
    ) -> Bool {
        guard isConnected, status == .powerOn else { return false }

        switch mode {
        case .mac:
            return false
        case .speaker:
            return true
        case .auto:
            guard speakerSources.contains(source) else { return false }
            return source.usesPlaybackStateForVolumeRouting ? isPlaying : true
        }
    }
}
