import KEFCore
import SwiftUI

struct MobileVolumeSettingsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let speakerID: String
    let records: SpeakerRecordStore
    let onApplyPreset: (VolumePreset) -> Void
    @State private var preferences: SpeakerVolumePreferences

    init(
        speakerID: String,
        records: SpeakerRecordStore = .shared,
        onApplyPreset: @escaping (VolumePreset) -> Void
    ) {
        self.speakerID = speakerID
        self.records = records
        self.onApplyPreset = onApplyPreset
        _preferences = State(initialValue: records.volumePreferences(for: speakerID))
    }

    private var limitToggle: some View {
        Toggle("Limit volume", isOn: Binding(
            get: { preferences.maximumVolume != nil },
            set: { preferences.maximumVolume = $0 ? 60 : nil }
        ))
        .accessibilityLabel("Limit volume")
        .accessibilityIdentifier("speaker-volume-limit-toggle")
    }

    var body: some View {
        Form {
            Section {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Limit volume")
                            .accessibilityHidden(true)
                        limitToggle
                            .labelsHidden()
                            .fixedSize()
                    }
                } else {
                    limitToggle
                }
                if preferences.maximumVolume != nil {
                    VolumePreferenceStepper(
                        title: "Maximum",
                        value: Binding(
                            get: { preferences.effectiveMaximumVolume },
                            set: { preferences.maximumVolume = $0 }
                        ),
                        identifier: "speaker-maximum-volume"
                    )
                }
            } header: {
                Text("Volume limit")
            } footer: {
                Text("Limits future volume commands from Ampestra, including Siri, widgets and volume buttons. Other apps and the speaker’s own controls can still change its volume.")
            }

            Section {
                ForEach($preferences.presets) { $preset in
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Preset name", text: $preset.name)
                            .accessibilityLabel("Preset name")
                        VolumePreferenceStepper(
                            title: "Volume", value: $preset.volume,
                            identifier: "preset-volume-\(preset.id)"
                        )
                        Button("Apply \(preset.name)") {
                            // Persist the current edit before enqueuing its command.
                            records.updateVolumePreferences(preferences, for: speakerID)
                            onApplyPreset(preset)
                        }
                            .disabled(preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { preferences.presets.remove(atOffsets: $0) }
                Button("Add preset", systemImage: "plus") {
                    preferences.presets.append(VolumePreset(name: "New preset", volume: 20))
                }
                .disabled(preferences.presets.count >= 12)
            } header: {
                Text("Presets")
            } footer: {
                Text("Preset volumes respect this speaker’s limit. Swipe to delete a preset.")
            }
        }
        .navigationTitle("Volume & Presets")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: preferences) { _, value in
            records.updateVolumePreferences(value, for: speakerID)
        }
    }
}

/// At accessibility sizes, controls get their own line so labels retain the full width.
private struct VolumePreferenceStepper: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    @Binding var value: Int
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                    Text("\(value)%")
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
                Stepper(title, value: $value, in: 0...100)
                    .labelsHidden()
                    .accessibilityLabel(title)
                    .accessibilityValue("\(value)%")
                    .accessibilityIdentifier(identifier)
            } else {
                Stepper(value: $value, in: 0...100) {
                    LabeledContent(title, value: "\(value)%")
                }
                .accessibilityLabel(title)
                .accessibilityValue("\(value)%")
                .accessibilityIdentifier(identifier)
            }
        }
    }
}
