import SwiftUI

struct VolumeStepSettingsRows: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            LabeledContent("Volume changes") {
                SettingsSegmentedControl(
                    accessibilityLabel: "Volume control",
                    options: [("Any Value", false), ("Fixed Steps", true)],
                    selection: fixedVolumeStepsBinding
                )
            }

            if appState.useFixedVolumeSteps {
                LabeledContent("Step size") {
                    HStack(spacing: 8) {
                        Text("\(appState.volumeStepSize)%")
                            .monospacedDigit()
                            .frame(minWidth: 34, alignment: .trailing)

                        Stepper(
                            "Step size",
                            value: volumeStepSizeBinding,
                            in: appState.allowedVolumeStepRange
                        )
                        .labelsHidden()
                        .accessibilityValue("\(appState.volumeStepSize) percent")
                    }
                    .fixedSize()
                    .help("Change the amount used by each volume adjustment")
                }
            }
        }
    }

    private var fixedVolumeStepsBinding: Binding<Bool> {
        Binding(
            get: { appState.useFixedVolumeSteps },
            set: { appState.setUseFixedVolumeSteps($0) }
        )
    }

    private var volumeStepSizeBinding: Binding<Int> {
        Binding(
            get: { appState.volumeStepSize },
            set: { appState.setVolumeStepSize($0) }
        )
    }
}
