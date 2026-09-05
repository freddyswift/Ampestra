import KEFCore
import SwiftUI

struct SpeakerVolumeSettingsSection: View {
    @EnvironmentObject private var appState: AppState
    @State private var isEditingPresets = false

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
                Button("Edit Presets…") { isEditingPresets = true }
            }
        } header: {
            Text("Speaker Volume")
        } footer: {
            Text("Saved for this speaker on this Mac. Limits apply to commands sent by Ampestra; other remotes can still change the volume.")
        }
        .disabled(appState.currentHost == nil)
        .sheet(isPresented: $isEditingPresets) {
            VolumePresetEditor(preferences: appState.speakerVolumePreferences) {
                appState.setSpeakerVolumePreferences($0)
            }
        }
    }
}

private struct VolumePresetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var preferences: SpeakerVolumePreferences
    let save: (SpeakerVolumePreferences) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Volume Presets").font(.headline)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach($preferences.presets) { $preset in
                        HStack {
                            TextField("Name", text: $preset.name)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Preset name")
                            Stepper(value: $preset.volume, in: 0...100) {
                                Text("\(preset.volume)%").monospacedDigit().frame(width: 42)
                            }
                            .accessibilityLabel("Preset volume")
                            Button {
                                preferences.presets.removeAll { $0.id == preset.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .accessibilityLabel("Delete preset \(preset.name)")
                        }
                    }
                }
            }
            Button("Add Preset") {
                preferences.presets.append(VolumePreset(name: "New Preset", volume: 25))
            }
            .disabled(preferences.presets.count >= 12)
            Text("Presets above your volume limit will use the limit.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(preferences); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(preferences.presets.contains { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
        }
        .padding(20)
        .frame(width: 430, height: 330)
    }
}
