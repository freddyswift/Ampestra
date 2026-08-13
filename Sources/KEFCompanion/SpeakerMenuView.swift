import AppKit
import SwiftUI

/// Primary menu-bar panel.
///
/// This view is intentionally state-driven and thin: it renders connection,
/// power, source, playback, and volume controls from `AppState`, while network
/// side effects stay in the state/controller layer.
struct SpeakerMenuView: View {
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject var appState: AppState

    @State private var sliderVolume: Double = 0
    @State private var panel: Panel = .controls

    private enum Panel: Hashable {
        case controls
        case onboarding
    }

    var body: some View {
        Group {
            switch panel {
            case .controls:
                controlsPanel
            case .onboarding:
                OnboardingView(
                    doneAction: {
                        appState.completeOnboarding()
                        setPanel(.controls)
                    },
                    settingsAction: {
                        showSettingsFrontmost()
                        setPanel(.controls)
                    }
                )
            }
        }
        .transition(.identity)
        .transaction { transaction in
            transaction.disablesAnimations = true
            transaction.animation = nil
        }
        .onAppear {
            if appState.shouldShowOnboarding {
                setPanel(.onboarding)
            } else {
                appState.completeOnboarding()
                appState.startConnectionIfNeeded()
            }
        }
    }

    private func showSettingsFrontmost() {
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setPanel(_ newPanel: Panel) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        transaction.animation = nil

        // Menu-bar popovers can look unstable when SwiftUI animates between
        // very different content heights. Switching panels without animation
        // keeps the window sizing deterministic.
        withTransaction(transaction) {
            panel = newPanel
        }
    }

    private var controlsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerSection
            subtleDivider

            ScrollView {
                Group {
                    if appState.isConnected {
                        connectedContent
                    } else {
                        disconnectedContent
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.never)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: 520)

            subtleDivider
            footerActions
        }
        .padding(12)
        .frame(width: MenuPanelLayout.width, alignment: .topLeading)
        .menuPanelSurface()
        .onChange(of: appState.displayedVolume) { _, newValue in
            sliderVolume = Double(newValue)
        }
        .onAppear {
            appState.setVolumeHUDSuppressed(true)
            sliderVolume = Double(appState.displayedVolume)
        }
        .onDisappear {
            appState.setVolumeHUDSuppressed(false)
        }
    }

    private var subtleDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.18))
            .frame(height: 1)
    }

    private var connectedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            primaryControlsSection

            if appState.status == .powerOn {
                volumeSection

                if supportsPlayerMetadata {
                    playbackSection
                }
            }

            if let actionError = appState.actionError {
                Label(actionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Speaker action failed: \(actionError)")
            }
        }
    }

    private var disconnectedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasSelectableSpeakers {
                selectableSpeakersSection
            } else {
                disconnectedActions
            }

            if appState.needsLocalNetworkAccess {
                Button {
                    appState.openLocalNetworkSettings()
                } label: {
                    Label("Open Local Network Settings", systemImage: "gearshape")
                }
                .controlSize(.small)
                .panelFloatingButtonStyle(prominent: true)
            }
        }
    }

    private var selectableSpeakersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                sectionLabel("Available")

                Spacer(minLength: 8)

                Button {
                    appState.scanForSpeakers()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 18, height: 18)
                }
                .controlSize(.small)
                .panelFloatingButtonStyle()
                .help("Rescan")
                .disabled(appState.discovery.isSearching || appState.isBusy)
            }

            ForEach(Array(selectableSpeakers.prefix(3))) { speaker in
                selectableSpeakerRow(speaker)
            }

            if selectableSpeakers.count > 3 {
                Button {
                    showSettingsFrontmost()
                } label: {
                    Label("\(selectableSpeakers.count - 3) more in Settings", systemImage: "ellipsis.circle")
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func selectableSpeakerRow(_ speaker: DiscoveredSpeaker) -> some View {
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
            .disabled(appState.isBusy || appState.isReconnecting)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .panelSolidCardBackground(
            RoundedRectangle(cornerRadius: 8, style: .continuous),
            fillOpacity: 0.20,
            strokeOpacity: 0.14
        )
    }

    private var disconnectedActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                disconnectedActionButtons
            }

            VStack(alignment: .leading, spacing: 8) {
                disconnectedActionButtons
            }
        }
    }

    @ViewBuilder
    private var disconnectedActionButtons: some View {
        if appState.speakerMAC != nil {
            Button("Wake Speaker") {
                appState.wakeSpeaker()
            }
            .controlSize(.small)
            .panelFloatingButtonStyle()
            .disabled(appState.isBusy || appState.isReconnecting)
        }

        Button(reconnectButtonTitle) {
            appState.startConnection()
        }
        .controlSize(.small)
        .panelFloatingButtonStyle(prominent: true)
        .disabled(appState.isBusy || appState.isReconnecting || appState.discovery.isSearching)

        Button("Connection Settings") {
            showSettingsFrontmost()
        }
        .controlSize(.small)
        .panelFloatingButtonStyle()
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)

                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

            }

            Spacer(minLength: 8)
            statusBadge
        }
    }

    private var primaryControlsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Power")
                        .font(.subheadline)
                    Text(appState.status == .powerOn ? "Speaker is ready" : "Speaker is in standby")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if appState.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }

                Toggle("Power", isOn: Binding(
                    get: { appState.status == .powerOn },
                    set: { _ in appState.togglePower() }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(appState.isBusy)
            }

            if appState.status == .powerOn {
                subtleDivider

                LabeledContent {
                    Picker("Source", selection: Binding(
                        get: { appState.source },
                        set: { appState.setSource($0) }
                    )) {
                        ForEach(SpeakerSource.inputSources) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 138)
                    .disabled(appState.isBusy)
                } label: {
                    Text("Source")
                        .font(.subheadline)
                }
                .font(.subheadline)
            }
        }
    }

    private var volumeSection: some View {
        MenuBarVolumeControl(
            volume: $sliderVolume,
            step: appState.volumeSliderStep,
            isDisabled: appState.isBusy || appState.status != .powerOn,
            volumeChanged: { newVolume in
                guard newVolume != appState.displayedVolume else { return }
                appState.commitVolume(newVolume)
            },
            muteAction: appState.toggleSpeakerMute
        )
    }

    private var playbackSection: some View {
        MenuBarPlaybackSection(
            nowPlaying: appState.nowPlaying,
            isPlaying: appState.isPlaying,
            isBusy: appState.isBusy,
            previousAction: appState.previousTrack,
            playPauseAction: appState.togglePlayPause,
            nextAction: appState.nextTrack
        )
    }

    private var footerActions: some View {
        HStack(spacing: 12) {
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }

            Spacer()

            Button(action: showSettingsFrontmost) {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            if appState.isBusy {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(statusBadgeColor)
                    .frame(width: 8, height: 8)
            }

            Text(statusBadgeText)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .panelSolidCardBackground(Capsule(style: .continuous), fillOpacity: 0.28, strokeOpacity: 0.16)
    }

    private var statusBadgeText: String {
        if appState.isBusy {
            return "Updating"
        }
        if !appState.isConnected {
            if hasSelectableSpeakers {
                return "Available"
            }
            if appState.isReconnecting {
                return "Reconnecting"
            }
            if appState.discovery.isSearching {
                return "Searching"
            }
            return appState.connectionError == nil ? "Offline" : "Error"
        }
        return appState.status == .powerOn ? "On" : "Standby"
    }

    private var statusBadgeColor: Color {
        if !appState.isConnected {
            if hasSelectableSpeakers {
                return .blue
            }
            return appState.connectionError == nil && !appState.isReconnecting ? .gray : .orange
        }
        return appState.status == .powerOn ? .green : .gray
    }

    private var headerTitle: String {
        if appState.isConnected {
            return appState.speakerName.isEmpty ? "KEF Speaker" : appState.speakerName
        }
        return disconnectedTitle
    }

    private var headerSubtitle: String {
        if appState.isConnected {
            let detail = [appState.speakerModel.nilIfEmpty, appState.currentHost]
                .compactMap { $0 }
                .joined(separator: " • ")
            return detail.isEmpty ? "Connected" : detail
        }

        if hasSelectableSpeakers {
            return "Select a speaker below to connect."
        }

        if let reconnectingHostDescription {
            return reconnectingHostDescription
        }

        if let error = appState.connectionError, !error.isEmpty {
            return error
        }

        return appState.discovery.isSearching
            ? "Looking for speakers on your network"
            : "Rescan or open Connection Settings to add a speaker."
    }

    private var disconnectedTitle: String {
        if appState.isBusy {
            return "Waking speaker"
        }
        if hasSelectableSpeakers {
            return "Choose a speaker"
        }
        if appState.isReconnecting {
            return "Reconnecting"
        }
        if appState.discovery.isSearching {
            return "Searching for speakers"
        }
        if appState.connectionError != nil {
            return "Connection issue"
        }
        return "No speaker connected"
    }

    private var selectableSpeakers: [DiscoveredSpeaker] {
        appState.discovery.speakers
    }

    private var hasSelectableSpeakers: Bool {
        !selectableSpeakers.isEmpty
    }

    private var supportsPlayerMetadata: Bool {
        appState.source == .wifi || appState.source == .bluetooth
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private var reconnectingHostDescription: String? {
        guard appState.isReconnecting, let host = appState.currentHost else { return nil }
        return "Trying \(host) again."
    }

    private var reconnectButtonTitle: String {
        if appState.isReconnecting {
            return "Reconnecting…"
        }
        if appState.discovery.isSearching {
            return "Scanning…"
        }
        return "Rescan"
    }

    private func isConnecting(to speaker: DiscoveredSpeaker) -> Bool {
        appState.isReconnecting && appState.currentHost == speaker.host
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
