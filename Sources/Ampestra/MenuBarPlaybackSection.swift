import SwiftUI

/// Compact media context and transport controls for the menu-bar panel.
struct MenuBarPlaybackSection: View {
    let nowPlaying: NowPlayingInfo?
    let isPlaying: Bool
    let isBusy: Bool
    let previousAction: () -> Void
    let playPauseAction: () -> Void
    let nextAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let nowPlaying, nowPlaying.hasInfo {
                HStack(alignment: .center, spacing: 9) {
                    Image(systemName: "music.note")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(PanelColors.rowFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                    metadata(nowPlaying)
                }
            } else {
                Text("Playback")
                    .font(.subheadline.weight(.medium))
            }

            HStack(spacing: 8) {
                Spacer()
                transportButton(
                    title: "Previous Track",
                    systemName: "backward.fill",
                    prominent: false,
                    action: previousAction
                )
                transportButton(
                    title: isPlaying ? "Pause" : "Play",
                    systemName: isPlaying ? "pause.fill" : "play.fill",
                    prominent: true,
                    action: playPauseAction
                )
                transportButton(
                    title: "Next Track",
                    systemName: "forward.fill",
                    prominent: false,
                    action: nextAction
                )
                Spacer()
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

    private func metadata(_ info: NowPlayingInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(info.title ?? "Current Track")
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .help(info.title ?? "Current Track")

            if let detail = metadataDetail(info) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(detail)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityMetadataLabel(info))
    }

    private func metadataDetail(_ info: NowPlayingInfo) -> String? {
        [info.artist, info.album]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
            .nilIfEmpty
    }

    private func accessibilityMetadataLabel(_ info: NowPlayingInfo) -> String {
        [info.title, info.artist, info.album]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    @ViewBuilder
    private func transportButton(
        title: String,
        systemName: String,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 22, height: 20)
        }
        .controlSize(.small)
        .disabled(isBusy)
        .help(title)
        .accessibilityLabel(title)

        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.borderless)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
