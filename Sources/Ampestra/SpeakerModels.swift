import Foundation

/// A speaker discovered from Bonjour.
///
/// `host` is the value the API client should connect to. It is usually an IPv4
/// address, but discovery can fall back to a `.local` hostname when IPv4 lookup
/// fails. `macAddress` is optional because it is learned from RAOP, not the HTTP
/// control service.
struct DiscoveredSpeaker: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let host: String
    let macAddress: String?
}

struct NowPlayingInfo: Equatable {
    var title: String?
    var artist: String?
    var album: String?

    var hasInfo: Bool {
        title != nil || artist != nil
    }
}

struct PlayerState: Equatable {
    var isPlaying: Bool
    var nowPlaying: NowPlayingInfo
}

/// Steady-state values fetched together during the regular polling loop.
struct SpeakerSnapshot: Equatable {
    var status: SpeakerStatus
    var source: SpeakerSource
    var volume: Int
    var name: String
    var model: String
}

/// User preference for how hardware volume keys should be routed.
///
/// Auto mode is intentionally source-aware. For WiFi/Bluetooth playback the app
/// only intercepts keys while the speaker reports active playback, allowing the
/// same keys to control macOS when the speaker is paused.
enum VolumeKeyRoutingMode: String, CaseIterable, Identifiable {
    case mac
    case auto
    case speaker

    var id: String { rawValue }

    var requiresMediaKeyAccess: Bool {
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
enum SpeakerSource: String, CaseIterable, Identifiable {
    case wifi
    case bluetooth
    case tv
    case optical
    case coaxial
    case analog
    case usb

    var id: String { rawValue }

    var displayName: String {
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

    var systemImage: String {
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

    static let inputSources: [SpeakerSource] = [
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
enum SpeakerStatus: String {
    case powerOn
    case standby
}

/// User-facing API errors. Low-level URLSession and decoding errors are mapped
/// into these cases where the app can provide a clearer connection message.
enum KEFError: LocalizedError {
    case invalidResponse
    case connectionFailed
    case apiError(String)

    var errorDescription: String? {
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
