import SwiftUI

struct SpeakerSettingsSection: View {
    @EnvironmentObject private var appState: AppState

    @State private var displayedDiscoveredSpeakers: [DiscoveredSpeaker] = []

    var body: some View {
        Group {
            if appState.needsLocalNetworkAccess {
                StatusRow(
                    title: "Local Network access is blocked",
                    detail: "macOS may show the switch as enabled while it refreshes this app's identity.",
                    systemImage: "hand.raised.circle",
                    tint: .orange
                ) {
                    Button("Open Settings") {
                        appState.openLocalNetworkSettings()
                    }
                    .controlSize(.small)
                }
            }

            if displayedDiscoveredSpeakers.isEmpty,
               !appState.discovery.isSearching,
               !appState.needsLocalNetworkAccess {
                StatusRow(
                    title: "No speakers found",
                    detail: "Rescan or open Connection to enter a host manually.",
                    systemImage: "hifispeaker",
                    tint: .secondary
                )
            }

            ForEach(displayedDiscoveredSpeakers) { speaker in
                discoveredSpeakerRow(speaker)
            }
        }
        .onAppear {
            updateDisplayedDiscoveredSpeakers()
            refreshDiscoveryIfNeeded()
        }
        .onChange(of: appState.discovery.speakers) { _, _ in
            updateDisplayedDiscoveredSpeakers()
        }
        .onChange(of: appState.isConnected) { _, _ in
            updateDisplayedDiscoveredSpeakers()
        }
        .onChange(of: appState.currentHost) { _, _ in
            updateDisplayedDiscoveredSpeakers()
        }
        .onChange(of: appState.speakerName) { _, _ in
            updateDisplayedDiscoveredSpeakers()
        }
    }

    private func discoveredSpeakerRow(_ speaker: DiscoveredSpeaker) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "hifispeaker.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.body.weight(.medium))
                .foregroundStyle(isCurrentSpeaker(speaker) ? Color.accentColor : .secondary)
                .frame(width: 30, height: 30)
                .background(
                    isCurrentSpeaker(speaker)
                        ? Color.accentColor.opacity(0.14)
                        : Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(speaker.name)
                    .font(.body)
                    .lineLimit(1)
                Text(speaker.host)
                    .font(.caption)
                    .foregroundStyle(PanelColors.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isCurrentSpeaker(speaker) {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.green)

                        Text("Connected")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                    Menu {
                        Button {
                            disconnectSpeaker(speaker)
                        } label: {
                            Label("Disconnect", systemImage: "power")
                        }

                        Button(role: .destructive) {
                            forgetSpeaker(speaker)
                        } label: {
                            Label("Forget Speaker", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .controlSize(.small)
                    .help("Speaker actions")
                    .accessibilityLabel("Speaker actions")
                }
            } else {
                Button("Connect") {
                    appState.connect(to: speaker.host)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }

    private func isCurrentSpeaker(_ speaker: DiscoveredSpeaker) -> Bool {
        appState.currentHost == speaker.host && appState.isConnected
    }

    private func disconnectSpeaker(_ speaker: DiscoveredSpeaker) {
        guard appState.currentHost == speaker.host else { return }
        appState.disconnect()
    }

    private func forgetSpeaker(_ speaker: DiscoveredSpeaker) {
        appState.forgetSpeaker(host: speaker.host)
    }

    private func updateDisplayedDiscoveredSpeakers() {
        var speakers = appState.discovery.speakers

        if appState.isConnected,
           let host = appState.currentHost,
           !speakers.contains(where: { $0.host == host }) {
            let name = appState.speakerName.isEmpty ? "Connected speaker" : appState.speakerName
            speakers.insert(
                DiscoveredSpeaker(id: "current-\(host)", name: name, host: host, macAddress: nil),
                at: 0
            )
        }

        if displayedDiscoveredSpeakers != speakers {
            displayedDiscoveredSpeakers = speakers
        }
    }

    private func refreshDiscoveryIfNeeded() {
        guard appState.hasStartedConnection,
              appState.useAutoDiscovery,
              appState.discovery.speakers.isEmpty,
              !appState.discovery.isSearching else {
            return
        }

        startDiscoveryFromSettings()
    }

    private func startDiscoveryFromSettings() {
        appState.scanForSpeakers()
    }
}
