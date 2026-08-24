import KEFCore
import SwiftUI

struct VolumeControlCard: View {
    @ObservedObject var store: RemoteStore
    let compact: Bool

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { Double(store.volume) },
            set: { store.previewVolume(Int($0.rounded())) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(
                    store.isMuted ? "Muted" : "Speaker volume",
                    systemImage: store.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
                )
                .font(.headline)

                Spacer()

                if store.isAdjustingVolume {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AmpestraTheme.accentBright)
                }
            }

            if let nowPlaying = store.nowPlaying {
                Spacer(minLength: compact ? 6 : 8)

                NowPlayingSummary(
                    info: nowPlaying,
                    isPlaying: store.isPlaying,
                    isBusy: store.isSendingCommand,
                    compact: compact,
                    previousAction: store.previousTrack,
                    playPauseAction: store.togglePlayPause,
                    nextAction: store.nextTrack
                )
            }

            Spacer(minLength: compact ? 7 : 10)

            VolumeGauge(
                value: store.volume,
                isMuted: store.isMuted,
                diameter: compact ? 104 : 146
            )

            Spacer(minLength: compact ? 7 : 10)

            volumeButtons

            Spacer(minLength: compact ? 7 : 10)

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
            .tint(AmpestraTheme.accent)
            .accessibilityValue("\(store.volume) percent")
        }
        .frame(maxHeight: .infinity)
        .padding(compact ? 16 : 20)
        .ampestraCard(cornerRadius: 28)
        .opacity(store.canControlSpeaker ? 1 : 0.5)
        .disabled(!store.canControlSpeaker)
    }

    private var volumeButtons: some View {
        GlassEffectContainer(spacing: 18) {
            volumeButtonsContent
        }
    }

    private var volumeButtonsContent: some View {
        HStack(spacing: 14) {
            volumeButton(systemName: "minus", label: "Volume down") {
                store.adjustVolume(direction: -1)
            }

            Button(action: store.toggleMute) {
                Image(systemName: store.isMuted ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: controlDiameter, height: controlDiameter)
            }
            .ampestraGlassButton(prominent: true)
            .buttonBorderShape(.circle)
            .tint(AmpestraTheme.accent)
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
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: controlDiameter, height: controlDiameter)
        }
        .ampestraGlassButton()
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }

    private func volumeEditingChanged(_ isEditing: Bool) {
        if !isEditing { store.commitPreviewedVolume() }
    }

    private var controlDiameter: CGFloat {
        compact ? 42 : 52
    }
}

private struct NowPlayingSummary: View {
    let info: NowPlayingInfo
    let isPlaying: Bool
    let isBusy: Bool
    let compact: Bool
    let previousAction: () -> Void
    let playPauseAction: () -> Void
    let nextAction: () -> Void

    var body: some View {
        VStack(spacing: compact ? 5 : 7) {
            HStack(spacing: compact ? 9 : 11) {
                RemoteIcon(
                    systemName: "music.note",
                    size: compact ? 34 : 38
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(info.title ?? "Now Playing")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AmpestraTheme.accentBright)
                }
            }

            HStack(spacing: compact ? 18 : 24) {
                transportButton(
                    title: "Previous track",
                    systemName: "backward.fill",
                    action: previousAction
                )
                transportButton(
                    title: isPlaying ? "Pause" : "Play",
                    systemName: isPlaying ? "pause.fill" : "play.fill",
                    prominent: true,
                    action: playPauseAction
                )
                transportButton(
                    title: "Next track",
                    systemName: "forward.fill",
                    action: nextAction
                )
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, compact ? 10 : 12)
        .padding(.vertical, compact ? 8 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AmpestraTheme.control,
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metadataAccessibilityLabel)
        .accessibilityAction(named: "Previous track", previousAction)
        .accessibilityAction(named: isPlaying ? "Pause" : "Play", playPauseAction)
        .accessibilityAction(named: "Next track", nextAction)
    }

    private func transportButton(
        title: String,
        systemName: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: compact ? 13 : 14, weight: .semibold))
                .frame(
                    width: compact ? 34 : 38,
                    height: compact ? 30 : 34
                )
                .background {
                    if prominent {
                        Circle().fill(AmpestraTheme.accent)
                    }
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(prominent ? Color.white : AmpestraTheme.accentBright)
        .contentShape(Rectangle())
        .disabled(isBusy)
        .opacity(isBusy ? 0.5 : 1)
        .accessibilityLabel(title)
    }

    private var detail: String? {
        let value = [info.artist, info.album]
            .compactMap { $0 }
            .joined(separator: " • ")
        return value.isEmpty ? nil : value
    }

    private var metadataAccessibilityLabel: String {
        let metadata = [info.title, info.artist, info.album]
            .compactMap { $0 }
            .joined(separator: ", ")
        return "\(isPlaying ? "Playing" : "Paused"), \(metadata)"
    }
}

private struct VolumeGauge: View {
    let value: Int
    let isMuted: Bool
    let diameter: CGFloat

    private var progress: CGFloat {
        CGFloat(min(100, max(0, value))) / 100
    }

    private var lineWidth: CGFloat {
        diameter * 0.075
    }

    var body: some View {
        ZStack {
            Circle()
                .inset(by: lineWidth / 2)
                .stroke(.quaternary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            Circle()
                .inset(by: lineWidth / 2)
                .trim(from: 0, to: progress)
                .stroke(
                    AmpestraTheme.accent,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.snappy(duration: 0.22), value: value)

            if progress > 0.015 {
                Circle()
                    .fill(AmpestraTheme.surface)
                    .frame(width: lineWidth * 1.55, height: lineWidth * 1.55)
                    .overlay {
                        Circle()
                            .stroke(AmpestraTheme.accent, lineWidth: max(2, lineWidth * 0.28))
                    }
                    .offset(y: -(diameter - lineWidth) / 2)
                    .rotationEffect(.degrees(Double(progress * 360)))
                    .animation(.snappy(duration: 0.22), value: value)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 3) {
                Text("\(value)")
                    .font(.system(size: diameter * 0.36, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(value)))

                Image(systemName: isMuted ? "speaker.slash.fill" : volumeSymbol)
                    .font(.system(size: diameter * 0.105, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Speaker volume")
        .accessibilityValue("\(value) percent")
    }

    private var volumeSymbol: String {
        switch value {
        case 0:
            "speaker.slash.fill"
        case 1...32:
            "speaker.wave.1.fill"
        case 33...66:
            "speaker.wave.2.fill"
        default:
            "speaker.wave.3.fill"
        }
    }
}

struct StandbyControlCard: View {
    @ObservedObject var store: RemoteStore
    let compact: Bool

    var body: some View {
        VStack(spacing: compact ? 12 : 18) {
            Spacer(minLength: 0)

            RemoteIcon(systemName: store.speakerStatus.systemImage, size: compact ? 46 : 58)

            VStack(spacing: 6) {
                Text(store.speakerStatus.detailText)
                    .font(.title3.weight(.semibold))
                Text(guidance)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if store.speakerStatus == .standby {
                Button(action: store.togglePower) {
                    Label("Power on", systemImage: "power")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .ampestraGlassButton(prominent: true)
                .buttonBorderShape(.capsule)
                .tint(AmpestraTheme.accent)
                .disabled(store.isSendingCommand)
            }

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .padding(compact ? 18 : 24)
        .ampestraCard(cornerRadius: 28)
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
    let compact: Bool

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            actionTiles
        }
    }

    private var actionTiles: some View {
        HStack(spacing: 12) {
            Button(action: store.togglePower) {
                ControlTileLabel(
                    icon: "power",
                    title: "Power",
                    value: store.speakerStatus == .powerOn ? "On" : "Standby",
                    compact: compact,
                    showsMenuIndicator: false
                )
            }
            .buttonStyle(.plain)
            .disabled(store.connectionState != .connected || store.isSendingCommand)

            Menu {
                ForEach(SpeakerSource.inputSources) { source in
                    Button {
                        store.setSource(source)
                    } label: {
                        Label(source.displayName, systemImage: source.systemImage)
                        if source == store.source { Image(systemName: "checkmark") }
                    }
                }
            } label: {
                ControlTileLabel(
                    icon: store.source.systemImage,
                    title: "Source",
                    value: store.source.displayName,
                    compact: compact,
                    showsMenuIndicator: true
                )
            }
            .tint(.primary)
            .disabled(!store.canControlSpeaker || store.isSendingCommand)
            .accessibilityLabel("Source, \(store.source.displayName)")
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
        Group {
            if compact {
                HStack(spacing: 10) {
                    RemoteIcon(systemName: icon, size: 36)

                    labels

                    Spacer(minLength: 2)
                    menuIndicator
                }
                .padding(12)
            } else {
                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        RemoteIcon(systemName: icon, size: 40)
                        Spacer()
                        menuIndicator
                    }

                    labels
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ampestraGlassControl(cornerRadius: 20)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var menuIndicator: some View {
        if showsMenuIndicator {
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}
