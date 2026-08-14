import KEFCore
import SwiftUI

struct KeyboardVolumeSettingsRows: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            LabeledContent("Volume keys") {
                SettingsSegmentedControl(
                    accessibilityLabel: "Keyboard volume target",
                    options: [
                        ("Mac", VolumeKeyRoutingMode.mac),
                        ("Automatic", VolumeKeyRoutingMode.auto),
                        ("KEF", VolumeKeyRoutingMode.speaker),
                    ],
                    selection: $appState.volumeKeyRoutingMode
                )
            }

            permissionStatus
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var permissionStatus: some View {
        if !appState.volumeKeyRoutingMode.requiresMediaKeyAccess {
            settingsNote(
                "Hardware volume keys control this Mac. Use the menu-bar panel for your KEF speaker."
            )
        } else if appState.mediaKeyAccessState == .working {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)

                Text(appState.volumeKeyRoutingMode == .auto
                    ? "KEF while playing; Mac when paused."
                    : "Hardware volume keys control your KEF speaker.")
                    .foregroundStyle(PanelColors.secondaryText)
            }
            .font(.caption)
        } else {
            MediaKeyPermissionFlowView()
        }
    }

    private func settingsNote(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)

            Text(text)
                .foregroundStyle(PanelColors.secondaryText)
        }
        .font(.caption)
    }
}
