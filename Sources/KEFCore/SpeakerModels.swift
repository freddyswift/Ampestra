import Foundation

/// A speaker discovered from Bonjour.
///
/// `host` is the `.local` hostname the API client should connect to, allowing
/// the system resolver to select IPv4 or IPv6. `macAddress` is optional because
/// it is learned from RAOP, not the HTTP control service.
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

/// State exposed by the KEF speaker-status endpoint, separate from the selected
/// physical source. Unknown values are preserved so a new firmware state is
/// never presented to the user as ordinary standby.
public enum SpeakerStatus: Hashable, Sendable {
    case powerOn
    case standby
    case networkSetup
    case firmwareUpgrade
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "powerOn":
            self = .powerOn
        case "standby":
            self = .standby
        case "networkSetup":
            self = .networkSetup
        case "firmwareUpgrade":
            self = .firmwareUpgrade
        default:
            self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .powerOn:
            "powerOn"
        case .standby:
            "standby"
        case .networkSetup:
            "networkSetup"
        case .firmwareUpgrade:
            "firmwareUpgrade"
        case .unknown(let value):
            value
        }
    }

    public var displayName: String {
        switch self {
        case .powerOn:
            "On"
        case .standby:
            "Standby"
        case .networkSetup:
            "Network setup"
        case .firmwareUpgrade:
            "Firmware update"
        case .unknown:
            "Unavailable"
        }
    }

    public var detailText: String {
        switch self {
        case .powerOn:
            "Speaker is ready"
        case .standby:
            "Speaker is in standby"
        case .networkSetup:
            "Speaker is in network setup"
        case .firmwareUpgrade:
            "Speaker is updating firmware"
        case .unknown(let value):
            value.isEmpty ? "Speaker status is unavailable" : "Speaker reported: \(value)"
        }
    }

    public var systemImage: String {
        switch self {
        case .powerOn:
            "power"
        case .standby:
            "moon.stars.fill"
        case .networkSetup:
            "wifi.exclamationmark"
        case .firmwareUpgrade:
            "arrow.triangle.2.circlepath"
        case .unknown:
            "questionmark.circle"
        }
    }

    public var allowsPowerToggle: Bool {
        self == .powerOn || self == .standby
    }
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
