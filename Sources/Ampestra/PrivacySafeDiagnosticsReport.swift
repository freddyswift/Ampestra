import Foundation
import KEFCore

@MainActor
enum PrivacySafeDiagnosticsReport {
    static func make(appState: AppState, updateController: UpdateController) -> String {
        let bundle = Bundle.main
        let appName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Ampestra"
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        return [
            "\(appName) Diagnostics",
            "Generated: \(Self.iso8601Formatter.string(from: Date()))",
            "",
            "App",
            "Version: \(shortVersion) (\(build))",
            "macOS: \(osVersion)",
            "",
            "Connection",
            "Connected: \(appState.isConnected)",
            "Reconnecting: \(appState.isReconnecting)",
            "Searching: \(appState.discovery.isSearching)",
            "Connection error present: \(appState.connectionError?.isEmpty == false)",
            "Manual host configured: \(!appState.manualIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
            "Current host present: \(appState.currentHost != nil)",
            "Discovered speaker count: \(appState.discovery.speakers.count)",
            "",
            "Speaker State",
            "Power status: \(diagnosticStatus(appState.status))",
            "Source: \(appState.source.rawValue)",
            "Playing: \(appState.isPlaying)",
            "",
            "Controls",
            "Volume step mode: \(appState.useFixedVolumeSteps ? "fixed" : "any")",
            "Volume step size: \(appState.volumeStepSize)",
            "Keyboard routing mode: \(appState.volumeKeyRoutingMode.rawValue)",
            "Keyboard KEF sources: \(appState.volumeKeyRoutingSources.map(\.rawValue).sorted().joined(separator: ","))",
            "Media-key access state: \(appState.mediaKeyAccessState)",
            "Media-key restart needed: \(appState.needsRestartForMediaKeyAccess)",
            "",
            "Updates",
            "Update configuration: \(updateController.configurationState)",
            "Can check for updates: \(updateController.canCheckForUpdates)",
        ].joined(separator: "\n")
    }

    private static func diagnosticStatus(_ status: KEFCore.SpeakerStatus) -> String {
        if case .unknown = status { return "unknown" }
        return status.rawValue
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
