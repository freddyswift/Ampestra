import KEFCore
import SwiftUI

struct VolumeControlCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var store: RemoteStore
    let compact: Bool
    @State private var previousSliderVolume: Int?

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { Double(store.volume) },
            set: { previewVolume(Int($0.rounded())) }
        )
    }

    var body: some View {
        VStack(spacing: compact ? 18 : 26) {
            Spacer(minLength: compact ? 8 : 14)

            VStack(spacing: compact ? 2 : 4) {
                HStack(spacing: 7) {
                    Image(systemName: store.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")

                    Text(store.isMuted ? "MUTED" : "SPEAKER VOLUME")
                }
                .font(.caption.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(store.isMuted ? .secondary : AmpestraTheme.accentBright)

                AnimatedVolumeNumber(
                    value: store.volume,
                    compact: compact,
                    emphasizesChange: previousSliderVolume == nil
                )
                    .foregroundStyle(store.isMuted ? .secondary : .primary)
                    .accessibilityLabel("Speaker volume, \(store.volume) percent")
            }

            Slider(
                value: volumeBinding,
                in: 0...100
            ) {
                Text("Speaker volume")
            } minimumValueLabel: {
                Image(systemName: "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } maximumValueLabel: {
                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } onEditingChanged: {
                volumeEditingChanged($0)
            }
            .controlSize(compact ? .regular : .large)
            .tint(AmpestraTheme.accent)
            .frame(maxWidth: 390)
            .animation(
                previousSliderVolume == nil ? .smooth(duration: 0.3) : nil,
                value: store.volume
            )
            .accessibilityValue("\(store.volume) percent")

            volumeButtons

            Spacer(minLength: compact ? 8 : 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, compact ? 8 : 14)
        .opacity(store.canControlSpeaker ? 1 : 0.5)
        .disabled(!store.canControlSpeaker)
    }

    private var volumeButtons: some View {
        GlassEffectContainer(spacing: 6) {
            volumeButtonsContent
        }
    }

    private var volumeButtonsContent: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: compact ? 10 : 12))
        return layout {
            volumeButton(systemName: "minus", label: "Volume down") {
                store.adjustVolume(direction: -1)
            }

            Button {
                RemoteHaptics.controlImpact()
                store.toggleMute()
            } label: {
                Label(
                    store.isMuted ? "Unmute" : "Mute",
                    systemImage: store.isMuted ? "speaker.wave.2.fill" : "speaker.slash.fill"
                )
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: compact ? 104 : 124, minHeight: controlDiameter)
                .fixedSize(horizontal: false, vertical: true)
            }
            .ampestraGlassButton(prominent: true)
            .buttonBorderShape(.capsule)
            .tint(AmpestraTheme.accent)
            .foregroundStyle(AmpestraTheme.onAccent)
            .accessibilityLabel(store.isMuted ? "Restore volume" : "Mute")

            volumeButton(systemName: "plus", label: "Volume up") {
                store.adjustVolume(direction: 1)
            }
        }
    }

    private func volumeButton(
        systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            RemoteHaptics.controlImpact()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: controlDiameter, height: controlDiameter)
        }
        .ampestraGlassButton()
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }

    private func volumeEditingChanged(_ isEditing: Bool) {
        if isEditing {
            previousSliderVolume = store.volume
        } else {
            previousSliderVolume = nil
            store.commitPreviewedVolume()
        }
    }

    private func previewVolume(_ value: Int) {
        let previous = previousSliderVolume ?? store.volume
        if VolumeHapticPolicy.crossesLandmark(from: previous, to: value) {
            RemoteHaptics.selection()
        }
        previousSliderVolume = value
        store.previewVolume(value)
    }

    private var controlDiameter: CGFloat {
        compact ? 40 : 48
    }
}

private struct AnimatedVolumeNumber: View {
    let value: Int
    let compact: Bool
    let emphasizesChange: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedValue: Int
    @State private var movesUp = true

    init(value: Int, compact: Bool, emphasizesChange: Bool) {
        self.value = value
        self.compact = compact
        self.emphasizesChange = emphasizesChange
        _displayedValue = State(initialValue: value)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(digitSlots) { slot in
                OdometerDigit(
                    value: slot.value,
                    fontSize: fontSize,
                    movesUp: movesUp,
                    reduceMotion: reduceMotion
                )
                .transition(digitInsertionTransition)
            }
        }
        .frame(width: compact ? 150 : 220, height: digitHeight)
        .clipped()
        .onChange(of: value) { _, newValue in
            updateDisplayedValue(to: newValue)
        }
    }

    private var digitSlots: [DigitSlot] {
        let leastSignificantFirst = String(displayedValue)
            .reversed()
            .compactMap(\.wholeNumberValue)

        return Array(
            leastSignificantFirst
                .enumerated()
                .map { DigitSlot(id: $0.offset, value: $0.element) }
                .reversed()
        )
    }

    private var digitInsertionTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .move(edge: movesUp ? .bottom : .top)
    }

    private func updateDisplayedValue(to newValue: Int) {
        guard newValue != displayedValue else { return }

        movesUp = newValue > displayedValue
        guard emphasizesChange, !reduceMotion else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                displayedValue = newValue
            }
            return
        }

        withAnimation(.smooth(duration: 0.24)) {
            displayedValue = newValue
        }
    }

    private var fontSize: CGFloat {
        compact ? 64 : 96
    }

    private var digitHeight: CGFloat {
        compact ? 78 : 116
    }

    private struct DigitSlot: Identifiable {
        let id: Int
        let value: Int
    }
}

private struct OdometerDigit: View {
    let value: Int
    let fontSize: CGFloat
    let movesUp: Bool
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            Text("\(value)")
                .font(.system(size: fontSize, weight: .medium, design: .rounded))
                .monospacedDigit()
                .id(value)
                .transition(digitTransition)
        }
        .frame(width: fontSize * 0.62, height: fontSize * 1.2)
        .clipped()
    }

    private var digitTransition: AnyTransition {
        guard !reduceMotion else { return .identity }

        return .asymmetric(
            insertion: .move(edge: movesUp ? .bottom : .top),
            removal: .move(edge: movesUp ? .top : .bottom)
        )
    }
}

struct PlaybackControlCard: View {
    @ObservedObject var store: RemoteStore
    let compact: Bool

    var body: some View {
        VStack(spacing: compact ? 10 : 14) {
            HStack(spacing: compact ? 10 : 12) {
                RemoteIcon(
                    systemName: store.isPlaying ? "waveform" : "music.note",
                    size: compact ? 38 : 44
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text("NOW PLAYING")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)

                    Text(store.nowPlaying?.title ?? "Current track")
                        .font(compact ? .subheadline.weight(.semibold) : .headline)
                        .lineLimit(1)

                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                if store.isSendingCommand {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AmpestraTheme.accentBright)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(metadataAccessibilityLabel)

            GlassEffectContainer(spacing: compact ? 16 : 20) {
                HStack(spacing: compact ? 16 : 20) {
                    transportButton(
                        title: "Previous track",
                        systemName: "backward.fill",
                        action: store.previousTrack
                    )
                    transportButton(
                        title: store.isPlaying ? "Pause" : "Play",
                        systemName: store.isPlaying ? "pause.fill" : "play.fill",
                        prominent: true,
                        action: store.togglePlayPause
                    )
                    transportButton(
                        title: "Next track",
                        systemName: "forward.fill",
                        action: store.nextTrack
                    )
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(compact ? 14 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ampestraCard()
    }

    private func transportButton(
        title: String,
        systemName: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            RemoteHaptics.controlImpact()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: compact ? 16 : 18, weight: .semibold))
                .frame(
                    width: controlDiameter(prominent: prominent),
                    height: controlDiameter(prominent: prominent)
                )
        }
        .ampestraGlassButton(prominent: prominent)
        .buttonBorderShape(.circle)
        .tint(AmpestraTheme.accent)
        .foregroundStyle(prominent ? AmpestraTheme.onAccent : AmpestraTheme.accentBright)
        .disabled(store.isSendingCommand || !store.canControlPlayback)
        .opacity(store.isSendingCommand ? 0.55 : 1)
        .accessibilityLabel(title)
    }

    private func controlDiameter(prominent: Bool) -> CGFloat {
        if compact { return prominent ? 48 : 42 }
        return prominent ? 56 : 48
    }

    private var detail: String? {
        let value = [store.nowPlaying?.artist, store.nowPlaying?.album]
            .compactMap { $0 }
            .joined(separator: " • ")
        return value.isEmpty ? nil : value
    }

    private var metadataAccessibilityLabel: String {
        let metadata = [
            store.nowPlaying?.title,
            store.nowPlaying?.artist,
            store.nowPlaying?.album,
        ]
            .compactMap { $0 }
            .joined(separator: ", ")
        return "\(store.isPlaying ? "Playing" : "Paused"), \(metadata)"
    }
}

struct StandbyControlCard: View {
    @ObservedObject var store: RemoteStore
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 14 : 18) {
            HStack(alignment: .top, spacing: compact ? 12 : 14) {
                RemoteIcon(
                    systemName: store.speakerStatus.systemImage,
                    size: compact ? 42 : 48
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(store.speakerStatus.detailText)
                        .font(compact ? .headline : .title3.weight(.semibold))

                    Text(guidance)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            if store.speakerStatus == .standby {
                Button {
                    RemoteHaptics.controlImpact()
                    store.togglePower()
                } label: {
                    HStack(spacing: 9) {
                        if store.isSendingCommand {
                            ProgressView()
                                .controlSize(.small)
                                .tint(AmpestraTheme.onAccent)
                        } else {
                            Image(systemName: "power")
                        }

                        Text(store.isSendingCommand ? "Powering on…" : "Power on")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: compact ? 44 : 48)
                }
                .ampestraGlassButton(prominent: true)
                .buttonBorderShape(.capsule)
                .tint(AmpestraTheme.accent)
                .disabled(store.isSendingCommand)
            }
        }
        .padding(compact ? 16 : 20)
        .ampestraCard()
    }

    private var guidance: String {
        switch store.speakerStatus {
        case .standby:
            "Wake it to adjust volume or change the input source."
        case .networkSetup:
            "Finish network setup before using the remote."
        case .firmwareUpgrade:
            "Controls will return when the firmware update finishes."
        case .unknown:
            "Controls are paused until the speaker reports a ready state."
        case .powerOn:
            "Ready for remote control."
        }
    }
}

struct SpeakerActionsRow: View {
    @ObservedObject var store: RemoteStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let compact: Bool
    @State private var isShowingSourcePicker = false

    var body: some View {
        GlassEffectContainer(spacing: compact ? 8 : 10) {
            actionTiles
        }
        .sheet(isPresented: $isShowingSourcePicker) {
            NavigationStack {
                List { sourceOptions }
                    .navigationTitle("Source")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isShowingSourcePicker = false }
                        }
                    }
            }
        }
    }

    private var actionTiles: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: compact ? 8 : 10))
        return layout {
            Button {
                RemoteHaptics.controlImpact()
                store.togglePower()
            } label: {
                ControlTileLabel(
                    icon: "power",
                    title: "Power",
                    value: store.speakerStatus == .powerOn ? "On" : "Standby",
                    compact: compact,
                    showsMenuIndicator: false
                )
            }
            .ampestraGlassButton()
            .buttonBorderShape(.capsule)
            .frame(maxWidth: .infinity)
            .tint(.primary)
            .disabled(store.connectionState != .connected || store.isSendingCommand)

            sourceControl
            .ampestraGlassButton()
            .buttonBorderShape(.capsule)
            .frame(maxWidth: .infinity)
            .tint(.primary)
            .disabled(!store.canControlSpeaker || store.isSendingCommand)
            .accessibilityLabel("Source, \(store.source.displayName)")
            .accessibilityIdentifier("speaker-source-control")
        }
    }

    @ViewBuilder
    private var sourceControl: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Button { isShowingSourcePicker = true } label: { sourceLabel }
        } else {
            Menu { sourceOptions } label: { sourceLabel }
        }
    }

    private var sourceLabel: some View {
        ControlTileLabel(
            icon: store.source.systemImage,
            title: "Source",
            value: store.source.displayName,
            compact: compact,
            showsMenuIndicator: true
        )
    }

    private var sourceOptions: some View {
        ForEach(SpeakerSource.inputSources) { source in
            Button {
                if source != store.source {
                    RemoteHaptics.selection()
                    store.setSource(source)
                }
                isShowingSourcePicker = false
            } label: {
                Label(source.displayName, systemImage: source.systemImage)
                if source == store.source { Image(systemName: "checkmark") }
            }
            .accessibilityLabel(source.displayName)
        }
    }

}

private struct ControlTileLabel: View {
    let icon: String
    let title: String
    let value: String
    let compact: Bool
    let showsMenuIndicator: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: compact ? 17 : 18, weight: .semibold))
                .foregroundStyle(AmpestraTheme.accentBright)
                .frame(width: sideSlotWidth)
                .accessibilityHidden(true)

            labels
                .frame(maxWidth: .infinity)
            menuIndicator
        }
        .padding(.horizontal, compact ? 8 : 10)
        .frame(maxWidth: .infinity, minHeight: compact ? 40 : 44, alignment: .center)
        .contentShape(Capsule())
    }

    private var labels: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var menuIndicator: some View {
        ZStack {
            if showsMenuIndicator {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: sideSlotWidth)
        .accessibilityHidden(true)
    }

    private var sideSlotWidth: CGFloat {
        compact ? 25 : 28
    }
}
