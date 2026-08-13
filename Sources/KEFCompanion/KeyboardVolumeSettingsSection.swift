import SwiftUI

struct KeyboardVolumeSettingsSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsSection(title: "Keyboard Volume", systemImage: "keyboard") {
            SettingsControlRow("Target") {
                Picker("Keyboard volume target", selection: $appState.volumeKeyRoutingMode) {
                    Text("Mac").tag(VolumeKeyRoutingMode.mac)
                    Text("Auto").tag(VolumeKeyRoutingMode.auto)
                    Text("KEF").tag(VolumeKeyRoutingMode.speaker)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: SettingsMetrics.segmentedWidth)
            }

            permissionStatus

            if !appState.usesDefaultControlPreferences {
                SettingsControlRow("Defaults") {
                    Button {
                        appState.resetControlPreferences()
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                    .help("Reset volume step and keyboard volume settings")
                }
            }
        }
    }

    @ViewBuilder
    private var permissionStatus: some View {
        if !appState.volumeKeyRoutingMode.requiresMediaKeyAccess {
            StatusRow(
                title: "No extra access needed",
                detail: "Hardware volume keys control your Mac. Use the menu-bar controls for your KEF speaker.",
                systemImage: "checkmark.circle",
                tint: .secondary
            )
        } else if appState.mediaKeyAccessState == .working {
            StatusRow(
                title: appState.volumeKeyRoutingMode == .auto ? "Automatic routing ready" : "KEF routing ready",
                detail: appState.volumeKeyRoutingMode == .auto
                    ? "KEF while playing; Mac when paused."
                    : "Hardware volume keys control your KEF speaker.",
                systemImage: "checkmark.circle.fill",
                tint: .green
            )
        } else {
            MediaKeyPermissionFlowView()
        }
    }
}
