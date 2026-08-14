import AppKit
import KEFCore
import SwiftUI

/// First-run speaker setup. Local Network access is requested only after the
/// user chooses to find a speaker; optional keyboard permissions live in
/// Settings alongside the feature that needs them.
struct OnboardingView: View {
    @EnvironmentObject var appState: AppState

    let doneAction: () -> Void
    let settingsAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView {
                speakerStatusCard
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.never)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: 520)
            footer
        }
        .padding(16)
        .frame(width: MenuPanelLayout.width, alignment: .topLeading)
        .menuPanelSurface()
        .onAppear {
            if !appState.shouldShowOnboarding {
                appState.completeOnboarding()
                doneAction()
            }
        }
        .onChange(of: appState.isConnected) { _, isConnected in
            guard isConnected else { return }
            appState.completeOnboarding()
            doneAction()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard appState.hasStartedConnection, appState.needsLocalNetworkAccess else { return }
            appState.startConnection()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color(nsColor: .selectedControlColor).opacity(0.14))
                    .frame(width: 38, height: 38)

                Image(systemName: "hifispeaker.2.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Welcome to Ampestra")
                    .font(.headline.weight(.semibold))
                Text("Connect to a KEF speaker on your local network.")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(PanelColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var speakerStatusCard: some View {
        OnboardingCard(title: "Choose Speaker", systemImage: "hifispeaker") {
            StatusRow(
                title: speakerStatusTitle,
                detail: speakerStatusDetail,
                systemImage: speakerStatusIcon,
                tint: speakerStatusTint
            ) {
                if appState.isReconnecting || appState.discovery.isSearching {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if appState.needsLocalNetworkAccess {
                Button {
                    appState.openLocalNetworkSettings()
                } label: {
                    Label("Open Local Network Settings", systemImage: "gearshape")
                }
                .controlSize(.small)
            } else if !appState.isConnected && !discoveredSpeakers.isEmpty {
                ForEach(Array(discoveredSpeakers.prefix(3))) { speaker in
                    discoveredSpeakerButton(speaker)
                }

                if discoveredSpeakers.count > 3 {
                    Button {
                        settingsAction()
                    } label: {
                        Label("\(discoveredSpeakers.count - 3) more in Settings", systemImage: "ellipsis.circle")
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                }
            } else if !appState.hasStartedConnection {
                Button {
                    appState.startConnection()
                } label: {
                    Label("Find Speakers", systemImage: "magnifyingglass")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            } else if !appState.isConnected && !appState.discovery.isSearching {
                HStack(spacing: 8) {
                    Button {
                        appState.startConnection()
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)

                    Button {
                        settingsAction()
                    } label: {
                        Label("Connection Settings", systemImage: "gearshape")
                    }
                    .controlSize(.small)
                }
            } else if !appState.isConnected {
                Button {
                    settingsAction()
                } label: {
                    Label("Connection Settings", systemImage: "gearshape")
                }
                .controlSize(.small)
            }
        }
    }

    private func discoveredSpeakerButton(_ speaker: DiscoveredSpeaker) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: "hifispeaker.fill")
                .foregroundStyle(.blue)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(speaker.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                Text(speaker.host)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                appState.connect(to: speaker.host)
            } label: {
                if isConnecting(to: speaker) {
                    Label("Connecting…", systemImage: "ellipsis")
                } else {
                    Label("Connect", systemImage: "link")
                }
            }
            .controlSize(.small)
            .disabled(appState.isReconnecting || appState.isBusy)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .panelSolidCardBackground(
            RoundedRectangle(cornerRadius: 8, style: .continuous),
            fillOpacity: 0.20,
            strokeOpacity: 0.14
        )
    }

    private var footer: some View {
        HStack {
            Button("Settings") {
                settingsAction()
            }
            .controlSize(.small)

            Spacer()

            Button("Not Now") {
                doneAction()
            }
            .controlSize(.small)
        }
    }

    private var speakerStatusTitle: String {
        if appState.isConnected {
            return appState.speakerName.isEmpty ? "Connected" : appState.speakerName
        }
        if appState.needsLocalNetworkAccess {
            return "Local Network access is off"
        }
        if appState.isReconnecting {
            return "Connecting to speaker"
        }
        if appState.connectionError != nil {
            return "Couldn't connect"
        }
        if !discoveredSpeakers.isEmpty {
            return discoveredSpeakers.count == 1 ? "Speaker found" : "\(discoveredSpeakers.count) speakers found"
        }
        if appState.discovery.isSearching {
            return "Searching for speakers"
        }
        if !appState.hasStartedConnection {
            return "Find your KEF speaker"
        }
        return "No speakers found"
    }

    private var speakerStatusDetail: String? {
        if appState.isConnected, let host = appState.currentHost {
            return host
        }
        if appState.needsLocalNetworkAccess {
            return "macOS reports that this app is blocked, even though System Settings may show it as enabled."
        }
        if appState.isReconnecting, let host = appState.currentHost {
            return host
        }
        if let connectionError = appState.connectionError {
            return connectionError
        }
        if !discoveredSpeakers.isEmpty {
            return "Select a speaker below to connect."
        }
        if appState.discovery.isSearching {
            return "Looking on your local network."
        }
        if !appState.hasStartedConnection {
            return "Finding and controlling a speaker requires Local Network access. macOS will ask after you continue."
        }
        return "Keep your speaker on this network, rescan, or add a manual host in Settings."
    }

    private var speakerStatusIcon: String {
        if appState.isConnected { return "checkmark.circle.fill" }
        if appState.needsLocalNetworkAccess { return "hand.raised.circle" }
        if appState.isReconnecting { return "hifispeaker.fill" }
        if !discoveredSpeakers.isEmpty { return "hifispeaker.fill" }
        if appState.discovery.isSearching { return "dot.radiowaves.left.and.right" }
        return "hifispeaker"
    }

    private var speakerStatusTint: Color {
        if appState.isConnected { return .green }
        if appState.needsLocalNetworkAccess || appState.connectionError != nil { return .orange }
        if !discoveredSpeakers.isEmpty { return .blue }
        return appState.discovery.isSearching ? .secondary : .blue
    }

    private func isConnecting(to speaker: DiscoveredSpeaker) -> Bool {
        appState.isReconnecting && appState.currentHost == speaker.host
    }

    private var discoveredSpeakers: [DiscoveredSpeaker] {
        appState.discovery.speakers
    }
}

private struct OnboardingCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))

            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelMaterialCardBackground(
            RoundedRectangle(cornerRadius: 8, style: .continuous),
            fillOpacity: 0.34,
            strokeOpacity: 0.18
        )
    }
}
