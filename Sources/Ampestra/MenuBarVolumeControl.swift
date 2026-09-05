import KEFCore
import SwiftUI

/// Immediate, precise volume control with accessible step buttons and mute.
struct MenuBarVolumeControl: View {
    @Binding var volume: Double

    let step: Double
    let maximumVolume: Int
    let isDisabled: Bool
    let volumeChanged: (Int) -> Void
    let muteAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("Volume")
                    .font(.subheadline.weight(.medium))

                Spacer()

                Text("\(Int(volume))%")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(PanelColors.secondaryText)
                    .accessibilityLabel("Volume \(Int(volume)) percent")
            }

            HStack(spacing: 6) {
                Button(action: muteAction) {
                    Image(systemName: volumeIcon)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(isDisabled)
                .help(volume == 0 ? "Restore Volume" : "Mute")
                .accessibilityLabel(volume == 0 ? "Restore Volume" : "Mute")

                stepButton(title: "Decrease Volume", systemName: "minus", atLimit: volume <= 0) {
                    adjustVolume(direction: -1)
                }

                Slider(value: Binding(get: { volume }, set: setVolume), in: 0...100, step: step)
                    .disabled(isDisabled)
                    .accessibilityLabel("Speaker Volume")
                    .accessibilityValue("\(Int(volume)) percent")

                stepButton(title: "Increase Volume", systemName: "plus", atLimit: volume >= Double(maximumVolume)) {
                    adjustVolume(direction: 1)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelGroupedBackground(
            RoundedRectangle(cornerRadius: 10, style: .continuous),
            fillOpacity: 0.38,
            strokeOpacity: 0.08
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
        guard !isDisabled else { return }
        let target = min(max(newValue, 0), Double(maximumVolume))
        guard target != volume else { return }
        volume = target
        // Only user edits send commands. Polling updates to the binding must
        // never write the speaker's reported volume back over the network.
        // Pass the requested step so AppState can snap before applying a
        // ceiling that may sit between steps (for example, a 43% limit).
        volumeChanged(Int(newValue))
    }

    private func adjustVolume(direction: Int) {
        let policy = VolumePolicy(usesFixedSteps: step > 1, stepSize: Int(step))
        setVolume(Double(policy.nextVolume(from: Int(volume), direction: direction)))
    }

    private func stepButton(title: String, systemName: String, atLimit: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 14, height: 14)
        }
        .controlSize(.mini)
        .panelContentButtonStyle()
        .disabled(isDisabled || atLimit)
        .help(title)
        .accessibilityLabel(title)
    }
}
