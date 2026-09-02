import KEFCore
import SwiftUI
import UIKit

struct ConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject var store: RemoteStore
    @ObservedObject private var discovery: KEFDiscovery
    @FocusState private var manualFieldFocused: Bool

    init(store: RemoteStore) {
        self.store = store
        _discovery = ObservedObject(wrappedValue: store.discovery)
    }

    private var manualHostIsValid: Bool {
        ManualHostValidator.normalizedHost(store.manualHost) != nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AmpestraBackdrop()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 18) {
                        ConnectionIntroCard()

                        if store.localNetworkPermissionDenied {
                            permissionCard
                        } else {
                            discoveryCard
                        }

                        manualAddressCard
                        ConnectionPrivacyNote()
                    }
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 34)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Connect speaker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if store.hasConfiguredSpeaker {
                        Button("Done", action: dismiss.callAsFunction)
                            .fontWeight(.semibold)
                    }
                }
            }
        }
        .tint(AmpestraTheme.accent)
        .interactiveDismissDisabled(!store.hasConfiguredSpeaker)
        .onAppear(perform: startDiscoveryIfNeeded)
        .onChange(of: store.connectionState, connectionStateChanged)
        .onDisappear(perform: store.stopDiscovery)
    }

    private var discoveryCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionLabel(
                    title: "Nearby speakers",
                    detail: discovery.isSearching ? "Searching" : nil
                )
                if discovery.isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AmpestraTheme.accentBright)
                }
            }

            if discovery.speakers.isEmpty {
                discoveryEmptyState
            } else {
                VStack(spacing: 10) {
                    ForEach(discovery.speakers) { speaker in
                        speakerButton(speaker)
                    }
                }

                Button(action: store.startDiscovery) {
                    Label("Scan again", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                }
                .disabled(discovery.isSearching || store.connectionState.isWorking)
            }

            if let error = discovery.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .ampestraCard()
    }

    private var discoveryEmptyState: some View {
        VStack(spacing: 14) {
            RemoteIcon(
                systemName: discovery.isSearching
                    ? "antenna.radiowaves.left.and.right"
                    : "hifispeaker.2.fill",
                size: 54
            )

            VStack(spacing: 4) {
                Text(discovery.isSearching ? "Searching your network" : "No speakers found yet")
                    .font(.headline)
                Text(discovery.isSearching ? "This usually takes a few seconds." : "Check Wi‑Fi, then try another scan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(action: discoveryButtonTapped) {
                Label(
                    discovery.isSearching ? "Stop searching" : "Find speakers",
                    systemImage: discovery.isSearching ? "stop.fill" : "antenna.radiowaves.left.and.right"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
            }
            .ampestraGlassButton(prominent: true)
            .buttonBorderShape(.capsule)
            .tint(discovery.isSearching ? AmpestraTheme.surfaceStrong : AmpestraTheme.accent)
            .disabled(store.connectionState.isWorking)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }

    private var manualAddressCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(title: "Manual connection")

            Text("Enter the private address shown in KEF Connect or your router.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                TextField("192.168.1.24", text: $store.manualHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                    .textContentType(.URL)
                    .font(.body.monospaced())
                    .focused($manualFieldFocused)
                    .submitLabel(.go)
                    .onSubmit(connectManually)
                    .textFieldStyle(.roundedBorder)
                    .frame(height: 50)

                Button(action: connectManually) {
                    Group {
                        if store.connectionState.isWorking {
                            ProgressView()
                                .tint(AmpestraTheme.onAccent)
                        } else {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 17, weight: .bold))
                        }
                    }
                    .frame(width: 50, height: 50)
                }
                .ampestraGlassButton(prominent: true)
                .buttonBorderShape(.circle)
                .tint(AmpestraTheme.accent)
                .disabled(!manualHostIsValid || store.connectionState.isWorking)
                .accessibilityLabel("Connect to manual address")
            }

            if !store.manualHost.isEmpty, !manualHostIsValid {
                Label("Use a private IP address or a .local hostname.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if case .failed(let message) = store.connectionState {
                Label(message, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(20)
        .ampestraCard()
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            RemoteIcon(systemName: "lock.trianglebadge.exclamationmark.fill", color: .orange, size: 50)

            Text("Local Network access is off")
                .font(.headline)
            Text("Allow Local Network access for Ampestra, then return here to scan again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button(action: openAppSettings) {
                Label("Open Settings", systemImage: "arrow.up.forward.app")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
            }
            .ampestraGlassButton(prominent: true)
            .buttonBorderShape(.capsule)
            .tint(.orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            Color.orange.opacity(0.08),
            in: RoundedRectangle(
                cornerRadius: AmpestraTheme.cardCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(cornerRadius: AmpestraTheme.cardCornerRadius, style: .continuous)
                .stroke(Color.orange.opacity(0.22), lineWidth: 1)
        }
    }

    private func speakerButton(_ speaker: DiscoveredSpeaker) -> some View {
        Button {
            store.connect(to: speaker)
        } label: {
            HStack(spacing: 13) {
                RemoteIcon(systemName: "hifispeaker.fill", size: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(speaker.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(speaker.host)
                        .font(.caption.monospaced())
                        .foregroundStyle(AmpestraTheme.mutedText)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(
                AmpestraTheme.control,
                in: RoundedRectangle(
                    cornerRadius: AmpestraTheme.nestedCornerRadius,
                    style: .continuous
                )
            )
            .contentShape(
                RoundedRectangle(
                    cornerRadius: AmpestraTheme.nestedCornerRadius,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(store.connectionState.isWorking)
    }

    private func discoveryButtonTapped() {
        if discovery.isSearching {
            store.stopDiscovery()
        } else {
            store.startDiscovery()
        }
    }

    private func startDiscoveryIfNeeded() {
        guard discovery.speakers.isEmpty, !store.localNetworkPermissionDenied else { return }
        store.startDiscovery()
    }

    private func connectManually() {
        guard manualHostIsValid else { return }
        manualFieldFocused = false
        store.connect(to: store.manualHost)
    }

    private func openAppSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(settingsURL)
    }

    private func connectionStateChanged(
        _ oldValue: SpeakerConnectionState,
        _ newValue: SpeakerConnectionState
    ) {
        if newValue == .connected { dismiss() }
    }
}
