import AppKit
import KEFCore
import OSLog
import SwiftUI

struct AmpestraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState(startImmediately: false)
    @StateObject private var updateController = UpdateController()

    var body: some Scene {
        // `MenuBarExtra` is the primary UI. The app uses accessory activation so
        // it behaves like a menu-bar utility rather than a document app.
        MenuBarExtra {
            SpeakerMenuView()
                .environmentObject(appState)
        } label: {
            Image(systemName: statusItemImageName)
                .symbolRenderingMode(.monochrome)
                .accessibilityLabel(statusItemAccessibilityLabel)
                .help(statusItemAccessibilityLabel)
                .onAppear {
                    appState.startConnectionForReturningUserIfNeeded()
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(updateController)
        }
    }

    private var statusItemImageName: String {
        appState.isConnected && appState.status == .powerOn
            ? "hifispeaker.fill"
            : "hifispeaker"
    }

    private var statusItemAccessibilityLabel: String {
        if appState.isConnected {
            let name = appState.speakerName.isEmpty ? "KEF speaker" : appState.speakerName
            return appState.status == .powerOn
                ? "\(name), ready"
                : "\(name), standby"
        }
        if appState.isReconnecting {
            return "Ampestra, reconnecting"
        }
        if appState.discovery.isSearching {
            return "Ampestra, searching for speakers"
        }
        if appState.connectionError != nil {
            return "Ampestra, connection issue"
        }
        return "Ampestra, no speaker connected"
    }
}

/// Runs the SwiftUI app from either the normal production executable or the
/// stable development launcher payload.
@MainActor
public func runAmpestraApp() {
    AmpestraApp.main()
}

/// C-compatible entry point loaded by the stable development launcher. The
/// launcher itself never changes when app code is rebuilt, keeping the main
/// executable UUID used by macOS Local Network privacy stable.
@_cdecl("AmpestraDevMain")
@MainActor
public func ampestraDevMain() {
    AmpestraApp.main()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let diagnosticLogger = Logger(
        subsystem: "com.freddyswift.ampestra.macos.dev",
        category: "LocalNetworkDiagnostic"
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        runDevelopmentNetworkDiagnosticIfRequested()
    }

    /// Exercises the speaker connection from the signed Dev app process. A
    /// Terminal-side curl is not equivalent because Local Network privacy is
    /// evaluated against the calling executable's identity.
    private func runDevelopmentNetworkDiagnosticIfRequested() {
        guard Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true else { return }

        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "--diagnose-local-network"),
              arguments.indices.contains(flagIndex + 1) else {
            return
        }

        let suppliedHost = arguments[flagIndex + 1]
        guard let host = ManualHostValidator.normalizedHost(suppliedHost) else {
            finishDevelopmentNetworkDiagnostic(
                message: "AMPESTRA_DIAGNOSTIC_INVALID_HOST\n",
                exitCode: 2
            )
            return
        }

        Task { @MainActor in
            do {
                let speaker = KEFSpeakerAPI(host: host)
                try await speaker.validateConnection()
                let name = try await speaker.getSpeakerName()
                let model = try await speaker.getModel()
                finishDevelopmentNetworkDiagnostic(
                    message: "AMPESTRA_DIAGNOSTIC_OK host=\(host) name=\(name) model=\(model)\n",
                    exitCode: 0
                )
            } catch {
                let nsError = error as NSError
                finishDevelopmentNetworkDiagnostic(
                    message: "AMPESTRA_DIAGNOSTIC_FAILED domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)\n",
                    exitCode: 1
                )
            }
        }
    }

    private func finishDevelopmentNetworkDiagnostic(message: String, exitCode: Int32) {
        FileHandle.standardOutput.write(Data(message.utf8))
        fflush(stdout)

        let logMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if exitCode == 0 {
            diagnosticLogger.notice("\(logMessage, privacy: .public)")
        } else {
            diagnosticLogger.error("\(logMessage, privacy: .public)")
        }

        // Give unified logging a chance to persist the final diagnostic before
        // the short-lived process exits.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            exit(exitCode)
        }
    }
}
