import KEFCore
import SwiftUI

struct SpeakerVolumeSettingsSection: View {
    @EnvironmentObject private var appState: AppState
    @State private var presetEditor: PresetEditorContext?

    private struct PresetEditorContext: Identifiable {
        let id = UUID()
        let host: String
        let presets: [VolumePreset]
    }

    var body: some View {
        Section {
            Toggle("Limit volume", isOn: Binding(
                get: { appState.speakerVolumePreferences.maximumVolume != nil },
                set: { enabled in
                    var preferences = appState.speakerVolumePreferences
                    preferences.maximumVolume = enabled ? 60 : nil
                    appState.setSpeakerVolumePreferences(preferences)
                }
            ))
            if appState.speakerVolumePreferences.maximumVolume != nil {
                Stepper(value: Binding(
                    get: { appState.maximumSpeakerVolume },
                    set: { maximum in
                        var preferences = appState.speakerVolumePreferences
                        preferences.maximumVolume = maximum
                        appState.setSpeakerVolumePreferences(preferences)
                    }
                ), in: 0...100) {
                    LabeledContent("Maximum", value: "\(appState.maximumSpeakerVolume)%")
                }
            }
            LabeledContent("Presets") {
                Button("Edit Presets…") {
                    guard let host = appState.currentHost else { return }
                    presetEditor = PresetEditorContext(host: host, presets: appState.speakerVolumePreferences.presets)
                }
            }
        } header: {
            Text("Speaker Volume")
        } footer: {
            Text("Saved for this speaker on this Mac. Limits apply to commands sent by Ampestra; other remotes can still change the volume.")
        }
        .disabled(appState.currentHost == nil)
        .sheet(item: $presetEditor) { editor in
            VolumePresetEditor(presets: editor.presets, canSave: appState.currentHost == editor.host) { presets in
                guard appState.currentHost == editor.host else { return }
                // Save only the edited presets, preserving a limit changed
                // while the sheet was open and never editing another speaker.
                var preferences = appState.speakerVolumePreferences
                preferences.presets = presets
                appState.setSpeakerVolumePreferences(preferences)
            }
        }
    }
}

private struct VolumePresetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var presets: [VolumePreset]
    let canSave: Bool
    let save: ([VolumePreset]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Volume Presets").font(.headline)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach($presets) { $preset in
                        HStack {
                            TextField("Name", text: $preset.name)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Preset name")
                            Stepper(value: $preset.volume, in: 0...100) {
                                Text("\(preset.volume)%").monospacedDigit().frame(width: 42)
                            }
                            .accessibilityLabel("Volume for \(preset.name)")
                            .accessibilityValue("\(preset.volume) percent")
                            Button {
                                presets.removeAll { $0.id == preset.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .accessibilityLabel("Delete preset \(preset.name)")
                        }
                    }
                }
            }
            Button("Add Preset") {
                presets.append(VolumePreset(name: "New Preset", volume: 25))
            }
            .disabled(presets.count >= 12)
            Text(editorStatus)
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(presets); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave || hasEmptyPresetName)
            }
        }
        .padding(20)
        .frame(width: 430, height: 330)
    }

    private var hasEmptyPresetName: Bool {
        presets.contains { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var editorStatus: String {
        if !canSave {
            return "Reconnect to the original speaker before saving these presets."
        }
        if hasEmptyPresetName {
            return "Each preset needs a name before you can save."
        }
        return "Presets above your volume limit will use the limit."
    }
}
