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
                if let speakerID = store.currentSpeakerID {
                    Section("Speaker volume") {
                        NavigationLink {
                            MobileVolumeSettingsView(speakerID: speakerID, records: store.speakerRecords) { preset in
                                store.setVolume(preset.volume)
                            }
                        } label: {
                            Label("Volume limit & presets", systemImage: "slider.horizontal.3")
                        }
                    }
                }
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

            NavigationLink {
                MobileDiagnosticsView(report: MobileDiagnosticsReport.make(store: store))
            } label: {
                Label("Diagnostics", systemImage: "doc.text.magnifyingglass")
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
            NavigationLink {
                SiriShortcutsHelpView(defaultSpeakerName: store.defaultSpeakerName)
            } label: {
                Label("How to use Siri", systemImage: "waveform.badge.mic")
            }

            ShortcutsLink()
                .shortcutsLinkStyle(.automaticOutline)
        } header: {
            Text("Siri & Shortcuts")
        } footer: {
            Text("Uses \(store.defaultSpeakerName) by default and runs on your local network.")
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

private struct SiriShortcutsHelpView: View {
    let defaultSpeakerName: String

    private let examples = [
        SiriCommandExample(
            id: "power",
            command: "Turn speakers on with Ampestra",
            systemImage: "power"
        ),
        SiriCommandExample(
            id: "source-tv",
            command: "Set speakers to TV with Ampestra",
            systemImage: "tv"
        ),
        SiriCommandExample(
            id: "volume-up",
            command: "Turn speakers up with Ampestra",
            systemImage: "speaker.plus.fill"
        ),
        SiriCommandExample(
            id: "mute",
            command: "Mute speakers with Ampestra",
            systemImage: "speaker.slash.fill"
        ),
        SiriCommandExample(
            id: "pause",
            command: "Pause with Ampestra",
            systemImage: "pause.fill"
        ),
    ]

    var body: some View {
        List {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Just ask Siri")
                            .fontWeight(.semibold)
                        Text("No setup is needed. \(defaultSpeakerName) is selected automatically.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            Section("Try saying") {
                ForEach(examples) { example in
                    Label {
                        Text("“\(example.command)”")
                            .accessibilityIdentifier("siri-command-\(example.id)")
                    } icon: {
                        Image(systemName: example.systemImage)
                            .foregroundStyle(AmpestraTheme.accent)
                    }
                }

                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("“Set speaker volume with Ampestra”")
                        Text("Siri will ask for a number from 0 to 100.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(AmpestraTheme.accent)
                }
            }

            Section {
                ShortcutsLink()
                    .shortcutsLinkStyle(.automaticOutline)
            } header: {
                Text("Customize")
            } footer: {
                Text("Use Shortcuts to combine speaker actions with scenes, schedules, or other apps.")
            }
        }
        .navigationTitle("Siri & Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SiriCommandExample: Identifiable {
    let id: String
    let command: String
    let systemImage: String
}
