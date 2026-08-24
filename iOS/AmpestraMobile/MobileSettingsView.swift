import AppIntents
import KEFCore
import SwiftUI
import UIKit

struct MobileSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject var store: RemoteStore
    @ObservedObject private var hardwareButtons: HardwareVolumeButtonController
    @State private var showingForgetConfirmation = false
    @State private var showingSiriTip = true

    let changeSpeaker: () -> Void

    init(store: RemoteStore, changeSpeaker: @escaping () -> Void) {
        self.store = store
        self.changeSpeaker = changeSpeaker
        _hardwareButtons = ObservedObject(wrappedValue: store.hardwareButtons)
    }

    var body: some View {
        NavigationStack {
            Form {
                speakerSection
                physicalButtonsSection
                if store.hasConfiguredSpeaker {
                    siriSection
                }
                moreSection
            }
            .formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss.callAsFunction)
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(AmpestraTheme.accent)
        .confirmationDialog(
            "Forget \(store.speakerName)?",
            isPresented: $showingForgetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget speaker", role: .destructive, action: forgetSpeaker)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You’ll need to discover or enter the speaker again before using the remote.")
        }
    }

    @ViewBuilder
    private var speakerSection: some View {
        Section {
            if store.currentHost != nil {
                LabeledContent("Name", value: store.speakerName)

                LabeledContent("Status") {
                    HStack(spacing: 7) {
                        ConnectionDot(state: store.connectionState)
                        Text(store.connectionState.title)
                            .foregroundStyle(.secondary)
                    }
                }

                Button(action: store.reconnectNow) {
                    actionLabel("Reconnect", systemImage: "arrow.clockwise")
                }
                .disabled(store.connectionState.isWorking)

                Button(action: changeSpeaker) {
                    actionLabel("Change speaker", systemImage: "hifispeaker.2")
                }

                Button(role: .destructive, action: confirmForgetSpeaker) {
                    actionLabel("Forget speaker", systemImage: "trash", color: .red)
                }
                .tint(.red)
            } else {
                Button(action: changeSpeaker) {
                    actionLabel("Choose speaker", systemImage: "hifispeaker.2")
                }
            }
        } header: {
            Text("Speaker")
        }
    }

    private var physicalButtonsSection: some View {
        Section {
            Toggle(isOn: $store.hardwareButtonsEnabled) {
                Label("Control speaker", systemImage: "iphone.gen3")
            }

            Toggle(isOn: $store.mutePhoneOnExit) {
                Label("Mute iPhone on exit", systemImage: "speaker.slash.fill")
            }

            Stepper(value: $store.volumeStep, in: VolumePolicy.allowedStepRange) {
                LabeledContent("Step", value: "\(store.volumeStep)%")
            }

            if let error = hardwareButtons.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Volume buttons")
        }
    }

    private var moreSection: some View {
        Section {
            LabeledContent {
                Text(store.localNetworkPermissionDenied ? "Off" : "Local only")
                    .foregroundStyle(networkStatusColor)
            } label: {
                Label(
                    "Local Network",
                    systemImage: store.localNetworkPermissionDenied ? "xmark.shield" : "checkmark.shield"
                )
                .foregroundStyle(networkStatusColor)
            }

            Button(action: openAppSettings) {
                actionLabel("App permissions", systemImage: "arrow.up.forward.app")
            }

        } header: {
            Text("More")
        }
    }

    private var siriSection: some View {
        Section {
            SiriTipView(intent: SetSpeakerPowerIntent(), isVisible: $showingSiriTip)
                .siriTipViewStyle(.automatic)

            ShortcutsLink()
                .shortcutsLinkStyle(.automaticOutline)
        } header: {
            Text("Siri & Shortcuts")
        } footer: {
            Text("Speaker control stays on your local network, including when Siri runs Ampestra in the background.")
        }
    }

    private var networkStatusColor: Color {
        store.localNetworkPermissionDenied ? .orange : .green
    }

    private func actionLabel(
        _ title: String,
        systemImage: String,
        color: Color = AmpestraTheme.accent
    ) -> some View {
        Label(title, systemImage: systemImage)
            .foregroundStyle(color)
    }

    private func confirmForgetSpeaker() {
        showingForgetConfirmation = true
    }

    private func forgetSpeaker() {
        store.disconnect(forget: true)
        changeSpeaker()
    }

    private func openAppSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(settingsURL)
    }
}
