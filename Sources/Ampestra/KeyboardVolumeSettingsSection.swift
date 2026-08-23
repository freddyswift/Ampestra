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
                        ("By Source", VolumeKeyRoutingMode.auto),
                        ("KEF", VolumeKeyRoutingMode.speaker),
                    ],
                    selection: $appState.volumeKeyRoutingMode
                )
            }

            if appState.volumeKeyRoutingMode == .auto {
                LabeledContent("Control KEF on") {
                    sourceGrid
                }
            }

            permissionStatus
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var permissionStatus: some View {
        if !appState.requiresMediaKeyAccess {
            settingsNote(
                "Hardware volume keys control this Mac. Use the menu-bar panel for your KEF speaker."
            )
        } else if appState.mediaKeyAccessState == .working {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)

                Text(routingStatusText)
                    .foregroundStyle(PanelColors.secondaryText)
            }
            .font(.caption)
        } else {
            MediaKeyPermissionFlowView()
        }
    }

    private var sourceGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
            ForEach(sourceRows.indices, id: \.self) { rowIndex in
                GridRow {
                    ForEach(sourceRows[rowIndex]) { source in
                        sourceToggle(source)
                    }

                    if sourceRows[rowIndex].count == 1 {
                        Color.clear
                            .frame(width: 108, height: 1)
                    }
                }
            }
        }
        .frame(width: SettingsMetrics.segmentedControlWidth, alignment: .leading)
    }

    private var sourceRows: [[SpeakerSource]] {
        stride(from: 0, to: SpeakerSource.inputSources.count, by: 2).map { index in
            Array(SpeakerSource.inputSources[index..<min(index + 2, SpeakerSource.inputSources.count)])
        }
    }

    private func sourceToggle(_ source: SpeakerSource) -> some View {
        Toggle(
            source.displayName,
            isOn: Binding(
                get: { appState.routesVolumeKeysToSpeaker(on: source) },
                set: { appState.setVolumeKeyRoutingEnabled($0, for: source) }
            )
        )
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .frame(width: 108, alignment: .leading)
    }

    private var routingStatusText: String {
        if appState.volumeKeyRoutingMode == .auto {
            "Selected sources route to KEF. Wi‑Fi and Bluetooth return to Mac while paused."
        } else {
            "Hardware volume keys control your KEF speaker."
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
