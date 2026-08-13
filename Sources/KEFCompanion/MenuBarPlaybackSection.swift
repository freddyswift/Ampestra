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
                metadata(nowPlaying)
                Divider()
            } else {
                Text("Playback")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }

            HStack(spacing: 12) {
                Spacer()
                transportButton(
                    title: "Previous Track",
                    systemName: "backward.fill",
                    action: previousAction
                )
                transportButton(
                    title: isPlaying ? "Pause" : "Play",
                    systemName: isPlaying ? "pause.fill" : "play.fill",
                    action: playPauseAction
                )
                transportButton(
                    title: "Next Track",
                    systemName: "forward.fill",
                    action: nextAction
                )
                Spacer()
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

    private func metadata(_ info: NowPlayingInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(info.title ?? "Current Track")
                .font(.callout.weight(.semibold))
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

    private func transportButton(title: String, systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 24, height: 24)
        }
        .controlSize(.small)
        .panelFloatingButtonStyle()
        .disabled(isBusy)
        .help(title)
        .accessibilityLabel(title)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
