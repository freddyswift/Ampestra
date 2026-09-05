import AppKit
import KEFCore
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
        VStack(alignment: .leading, spacing: 0) {
            headerSection
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            subtleDivider

            ScrollView {
                Group {
                    if appState.isConnected {
                        connectedContent
                    } else {
                        disconnectedContent
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.never)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: 520)
        }
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
                .panelContentButtonStyle(prominent: true)
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
                .panelContentButtonStyle()
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
        .panelGroupedBackground(
            RoundedRectangle(cornerRadius: 8, style: .continuous),
            fillOpacity: 0.34,
            strokeOpacity: 0.08
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
            .panelContentButtonStyle()
            .disabled(appState.isBusy || appState.isReconnecting)
        }

        Button(reconnectButtonTitle) {
            appState.startConnection()
        }
        .controlSize(.small)
        .panelContentButtonStyle(prominent: true)
        .disabled(appState.isBusy || appState.isReconnecting || appState.discovery.isSearching)

        Button("Connection Settings") {
            showSettingsFrontmost()
        }
        .controlSize(.small)
        .panelContentButtonStyle()
    }

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if appState.isBusy {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Circle()
                            .fill(statusBadgeColor)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                    }

                    Text(headerSubtitle)
                        .font(.caption)
                        .foregroundStyle(PanelColors.secondaryText)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(statusBadgeText), \(headerSubtitle)")
            }

            Spacer(minLength: 8)

            Menu {
                Button {
                    showSettingsFrontmost()
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }

                Divider()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit Ampestra", systemImage: "xmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 22, height: 18)
            }
            .menuIndicator(.hidden)
            .controlSize(.small)
            .panelFloatingButtonStyle()
            .help("Ampestra menu")
        }
    }

    private var primaryControlsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: appState.status.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Power")
                        .font(.subheadline.weight(.medium))
                    Text(appState.status.detailText)
                        .font(.caption)
                        .foregroundStyle(PanelColors.secondaryText)
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
                .disabled(appState.isBusy || !appState.status.allowsPowerToggle)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 6)

            if appState.status == .powerOn {
                subtleDivider
                    .padding(.leading, 29)

                HStack(spacing: 9) {
                    Image(systemName: appState.source.systemImage)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 18)

                    Text("Source")
                        .font(.subheadline.weight(.medium))

                    Spacer(minLength: 8)

                    sourceMenu
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 7)
            }
        }
        .padding(10)
        .panelGroupedBackground(
            RoundedRectangle(cornerRadius: 12, style: .continuous),
            fillOpacity: 0.32,
            strokeOpacity: 0.08
        )
    }

    private var sourceMenu: some View {
        Menu {
            ForEach(SpeakerSource.inputSources) { source in
                Button {
                    guard source != appState.source else { return }
                    appState.setSource(source)
                } label: {
                    Label(
                        source.displayName,
                        systemImage: source == appState.source ? "checkmark" : source.systemImage
                    )
                }
            }
        } label: {
            Text(appState.source.displayName)
                .font(.subheadline)
                .foregroundStyle(.primary)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .accessibilityLabel("Source")
            .accessibilityValue(appState.source.displayName)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(appState.isBusy)
        .help("Choose speaker source")
    }

    private var volumeSection: some View {
        VStack(spacing: 6) {
            MenuBarVolumeControl(
                volume: $sliderVolume,
                step: appState.volumeSliderStep,
                isDisabled: appState.isBusy || appState.status != .powerOn,
                volumeChanged: { newVolume in
                    guard newVolume != appState.displayedVolume else { return }
                    let target = appState.speakerVolumePreferences.clampedVolume(newVolume)
                    if newVolume != target { sliderVolume = Double(target) }
                    appState.commitVolume(target)
                },
                muteAction: appState.toggleSpeakerMute
            )
            if !appState.speakerVolumePreferences.presets.isEmpty {
                HStack {
                    Menu("Presets") {
                        ForEach(appState.speakerVolumePreferences.presets) { preset in
                            Button("\(String(preset.name.prefix(20))) · \(appState.speakerVolumePreferences.clampedVolume(preset.volume))%") {
                                appState.applyVolumePreset(preset)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(appState.isBusy || appState.status != .powerOn)
                    Spacer()
                    if appState.maximumSpeakerVolume < 100 {
                        Text("Limit \(appState.maximumSpeakerVolume)%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
            }
        }
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
        return appState.status.displayName
    }

    private var statusBadgeColor: Color {
        if !appState.isConnected {
            if hasSelectableSpeakers {
                return .blue
            }
            return appState.connectionError == nil && !appState.isReconnecting ? .gray : .orange
        }
        switch appState.status {
        case .powerOn:
            return .green
        case .standby:
            return .gray
        case .networkSetup, .firmwareUpgrade, .unknown:
            return .orange
        }
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
