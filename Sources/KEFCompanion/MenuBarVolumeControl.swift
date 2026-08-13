import SwiftUI

/// Immediate, precise volume control with accessible step buttons and mute.
struct MenuBarVolumeControl: View {
    @Binding var volume: Double

    let step: Double
    let isDisabled: Bool
    let volumeChanged: (Int) -> Void
    let muteAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Volume")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer()

                Text("\(Int(volume))")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Volume \(Int(volume)) percent")
            }

            HStack(spacing: 8) {
                Button(action: muteAction) {
                    Image(systemName: volumeIcon)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .help(volume == 0 ? "Restore Volume" : "Mute")
                .accessibilityLabel(volume == 0 ? "Restore Volume" : "Mute")

                stepButton(title: "Decrease Volume", systemName: "minus") {
                    setVolume(volume - step)
                }

                Slider(value: $volume, in: 0...100, step: step)
                    .disabled(isDisabled)
                    .accessibilityLabel("Speaker Volume")
                    .onChange(of: volume) { _, newValue in
                        guard !isDisabled else { return }
                        volumeChanged(Int(newValue))
                    }

                stepButton(title: "Increase Volume", systemName: "plus") {
                    setVolume(volume + step)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSolidCardBackground(
            RoundedRectangle(cornerRadius: 14, style: .continuous),
            fillOpacity: 0.24,
            strokeOpacity: 0.14
        )
    }

    private var volumeIcon: String {
        if volume == 0 {
            return "speaker.slash.fill"
        } else if volume < 33 {
            return "speaker.wave.1.fill"
        } else if volume < 66 {
            return "speaker.wave.2.fill"
        }
        return "speaker.wave.3.fill"
    }

    private func setVolume(_ newValue: Double) {
        volume = min(max(newValue, 0), 100)
    }

    private func stepButton(title: String, systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 16, height: 16)
        }
        .controlSize(.small)
        .panelFloatingButtonStyle()
        .disabled(isDisabled)
        .help(title)
        .accessibilityLabel(title)
    }
}
