import Foundation

/// A speaker discovered from Bonjour.
///
/// `host` is the value the API client should connect to. It is usually an IPv4
/// address, but discovery can fall back to a `.local` hostname when IPv4 lookup
/// fails. `macAddress` is optional because it is learned from RAOP, not the HTTP
/// control service.
public struct DiscoveredSpeaker: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let host: String
    public let macAddress: String?

    public init(id: String, name: String, host: String, macAddress: String?) {
        self.id = id
        self.name = name
        self.host = host
        self.macAddress = macAddress
    }
}

public struct NowPlayingInfo: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
    }

    public var hasInfo: Bool {
        title != nil || artist != nil
    }
}

public struct PlayerState: Equatable, Sendable {
    public var isPlaying: Bool
    public var nowPlaying: NowPlayingInfo

    public init(isPlaying: Bool, nowPlaying: NowPlayingInfo) {
        self.isPlaying = isPlaying
        self.nowPlaying = nowPlaying
    }
}

/// Steady-state values fetched together during the regular polling loop.
public struct SpeakerSnapshot: Equatable, Sendable {
    public var status: SpeakerStatus
    public var source: SpeakerSource
    public var volume: Int
    public var name: String
    public var model: String

    public init(status: SpeakerStatus, source: SpeakerSource, volume: Int, name: String, model: String) {
        self.status = status
        self.source = source
        self.volume = volume
        self.name = name
        self.model = model
    }
}

/// User preference for how hardware volume keys should be routed.
///
/// Auto mode is intentionally source-aware. Callers provide the set of sources
/// that should receive hardware-volume events. For WiFi/Bluetooth playback the
/// app only intercepts keys while the speaker reports active playback, allowing
/// the same keys to control macOS when the speaker is paused.
public enum VolumeKeyRoutingMode: String, CaseIterable, Identifiable, Sendable {
    case mac
    case auto
    case speaker

    public var id: String { rawValue }

    public var requiresMediaKeyAccess: Bool {
        switch self {
        case .mac:
            false
        case .auto, .speaker:
            true
        }
    }
}

/// Physical/logical sources exposed by the KEF local HTTP API.
///
/// The raw values are sent directly to the speaker, so changing them is a wire
/// protocol change rather than only a UI label change.
public enum SpeakerSource: String, CaseIterable, Hashable, Identifiable, Sendable {
    case wifi
    case bluetooth
    case tv
    case optical
    case coaxial
    case analog
    case usb

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .wifi:
            "Wi‑Fi"
        case .bluetooth:
            "Bluetooth"
        case .tv:
            "TV"
        case .optical:
            "Optical"
        case .coaxial:
            "Coaxial"
        case .analog:
            "Analog"
        case .usb:
            "USB"
        }
    }

    public var systemImage: String {
        switch self {
        case .wifi:
            "wifi"
        case .bluetooth:
            "wave.3.right"
        case .tv:
            "tv"
        case .optical:
            "opticaldisc"
        case .coaxial:
            "cable.connector"
        case .analog:
            "waveform"
        case .usb:
            "cable.connector.horizontal"
        }
    }

    /// Network playback can report whether audio is actively playing. The
    /// remaining physical inputs cannot, so an enabled input routes whenever
    /// it is selected and the speaker is powered on.
    public var usesPlaybackStateForVolumeRouting: Bool {
        self == .wifi || self == .bluetooth
    }

    public static let inputSources: [SpeakerSource] = [
        .wifi,
        .bluetooth,
        .tv,
        .optical,
        .coaxial,
        .analog,
        .usb,
    ]
}

/// Minimal power state used by the panel. The KEF API exposes this through the
/// speaker status endpoint, separate from the selected physical source.
public enum SpeakerStatus: String, Sendable {
    case powerOn
    case standby
}

/// User-facing API errors. Low-level URLSession and decoding errors are mapped
/// into these cases where the app can provide a clearer connection message.
public enum KEFError: LocalizedError, Sendable {
    case invalidResponse
    case connectionFailed
    case apiError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Invalid response from speaker"
        case .connectionFailed:
            "Could not connect to speaker"
        case .apiError(let message):
            message
        }
    }
}
