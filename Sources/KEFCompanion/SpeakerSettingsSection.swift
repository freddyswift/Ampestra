import SwiftUI

struct SpeakerSettingsSection: View {
    @EnvironmentObject private var appState: AppState

    @State private var displayedDiscoveredSpeakers: [DiscoveredSpeaker] = []

    var body: some View {
        SettingsSection(title: "Speakers", systemImage: "hifispeaker") {
            speakerDiscoveryHeader

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
            } else if appState.discovery.isSearching {
                StatusRow(title: "Scanning your network", detail: nil, systemImage: "dot.radiowaves.left.and.right", tint: .secondary) {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if displayedDiscoveredSpeakers.isEmpty,
               !appState.discovery.isSearching,
               !appState.needsLocalNetworkAccess {
                StatusRow(
                    title: "No speakers found",
                    detail: "Open Advanced for manual connection options.",
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

    private var speakerDiscoveryHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                VStack(alignment: .leading, spacing: 2) {
                    Text(discoverySummaryText)
                        .font(.subheadline.weight(.medium))

                    Text(discoveryRecencyText(now: timeline.date))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(PanelColors.secondaryText)
                }
            }

            Spacer(minLength: 10)

            Button {
                startDiscoveryFromSettings()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .panelFloatingButtonStyle()
            .disabled(appState.discovery.isSearching)
        }
        .frame(minHeight: 34)
    }

    private func discoveredSpeakerRow(_ speaker: DiscoveredSpeaker) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(speaker.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(discoveredSpeakerDetail(speaker))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(PanelColors.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if appState.currentHost == speaker.host && appState.isConnected {
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
                    HStack(spacing: 8) {
                        Label("Current", systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)

                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(PanelColors.secondaryText)
                    }
                    .accessibilityLabel("Current speaker actions")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .controlSize(.small)
                .help("Current speaker actions")
            } else {
                Button {
                    appState.connect(to: speaker.host)
                } label: {
                    Label("Use", systemImage: "checkmark")
                }
                .controlSize(.small)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private func discoveredSpeakerDetail(_ speaker: DiscoveredSpeaker) -> String {
        if appState.currentHost == speaker.host && appState.isConnected {
            return "\(speaker.host) · current speaker"
        }

        return speaker.host
    }

    private func disconnectSpeaker(_ speaker: DiscoveredSpeaker) {
        guard appState.currentHost == speaker.host else { return }
        appState.disconnect()
    }

    private func forgetSpeaker(_ speaker: DiscoveredSpeaker) {
        appState.forgetSpeaker(host: speaker.host)
    }

    private var discoverySummaryText: String {
        if appState.discovery.isSearching {
            return "Scanning"
        }

        let count = displayedDiscoveredSpeakers.count
        if count == 1 {
            return "1 speaker found"
        }

        return "\(count) speakers found"
    }

    private func discoveryRecencyText(now: Date) -> String {
        if appState.discovery.isSearching {
            return "Scanning now"
        }

        guard let lastDiscoveryStartedAt = appState.discovery.lastStartedAt else {
            return appState.discovery.speakers.isEmpty ? "Not scanned yet" : "Results from this session"
        }

        let elapsed = now.timeIntervalSince(lastDiscoveryStartedAt)
        if elapsed < 45 {
            return "Last scanned just now"
        }

        return "Last scanned \(Self.relativeDateFormatter.localizedString(for: lastDiscoveryStartedAt, relativeTo: now))"
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

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

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
