import Foundation

/// Only allowlisted categories enter a report; error descriptions and user content never do.
enum MobileDiagnosticCategory: String, CaseIterable, Sendable {
    case networkUnavailable = "network-unavailable"
    case timeout
    case unreachable
    case identityChanged = "identity-changed"
    case commandRejected = "command-rejected"
    case invalidResponse = "invalid-response"
    case localNetworkPermission = "local-network-permission"
    case invalidAddress = "invalid-address"
    case other

    static func classify(_ error: Error) -> Self {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost: return .networkUnavailable
            case .timedOut: return .timeout
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: return .unreachable
            case .badServerResponse, .cannotParseResponse: return .invalidResponse
            default: return .other
            }
        }
        if let error = error as? SpeakerCommandError {
            switch error {
            case .speakerIdentityChanged: return .identityChanged
            case .notOnSpeakerNetwork: return .networkUnavailable
            case .timedOut, .wakeTimedOut: return .timeout
            case .unreachable, .wakeFailed: return .unreachable
            case .invalidResponse: return .invalidResponse
            case .commandRejected: return .commandRejected
            default: return .other
            }
        }
        return .other
    }
}

struct MobileDiagnosticHistory {
    static let limit = 20
    private(set) var categories: [MobileDiagnosticCategory] = []

    mutating func record(_ category: MobileDiagnosticCategory) {
        categories.append(category)
        if categories.count > Self.limit { categories.removeFirst(categories.count - Self.limit) }
    }
}

@MainActor
enum MobileDiagnosticsReport {
    static func make(store: RemoteStore, bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let connection: String
        switch store.connectionState {
        case .disconnected: connection = "disconnected"
        case .connecting: connection = "connecting"
        case .connected: connection = "connected"
        case .reconnecting: connection = "reconnecting"
        case .failed: connection = "failed"
        }
        let categories = store.diagnosticHistory.categories.map(\.rawValue)
        return [
            "Ampestra iOS Diagnostics",
            "Version: \(version) (\(build))",
            "iOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "",
            "Connection: \(connection)",
            "Searching: \(store.discovery.isSearching)",
            "Saved speaker count: \(store.savedSpeakers.count)",
            "Current host present: \(store.currentHost != nil)",
            "Local Network permission denied: \(store.localNetworkPermissionDenied)",
            "Error present: \(store.lastError != nil)",
            "Hardware button error present: \(store.hardwareButtons.lastError != nil)",
            "",
            "Recent error categories (oldest first, up to \(MobileDiagnosticHistory.limit), this session):",
            categories.isEmpty ? "None" : categories.joined(separator: "\n"),
            "",
            "Excludes speaker names, addresses, identifiers, playback metadata, and error messages.",
        ].joined(separator: "\n")
    }
}
