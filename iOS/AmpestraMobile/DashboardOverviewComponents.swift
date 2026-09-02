import SwiftUI

struct SpeakerOverviewCard: View {
    @ObservedObject var store: RemoteStore
    let compact: Bool
    let chooseSpeaker: () -> Void
    let showSettings: () -> Void

    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            Button(action: chooseSpeaker) {
                HStack(spacing: compact ? 9 : 12) {
                    RemoteIcon(systemName: speakerIcon, size: compact ? 38 : 44)

                    VStack(alignment: .leading, spacing: compact ? 3 : 4) {
                        Text(store.speakerName)
                            .font(compact ? .headline : .title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        HStack(spacing: 7) {
                            if let notice = store.notice {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(AmpestraTheme.accentBright)
                                    .accessibilityHidden(true)

                                Text(notice)
                                    .foregroundStyle(AmpestraTheme.accentBright)
                            } else {
                                ConnectionDot(state: store.connectionState)

                                Text(statusText)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.subheadline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .contentTransition(.opacity)
                    }

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens speaker connection options")

            HStack(spacing: compact ? 6 : 8) {
                if store.connectionState.isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AmpestraTheme.accentBright)
                        .frame(width: 30, height: 30)
                } else if shouldShowRefresh {
                    Button(action: refreshSpeaker) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .ampestraGlassButton()
                    .buttonBorderShape(.circle)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(refreshAccessibilityLabel)
                } else {
                    if !store.hasConfiguredSpeaker {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 30, height: 30)
                    }
                }

                Button(action: showSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .ampestraGlassButton()
                .buttonBorderShape(.circle)
                .foregroundStyle(AmpestraTheme.accentBright)
                .accessibilityLabel("Settings")
            }
        }
        .padding(.horizontal, compact ? 12 : 15)
        .padding(.vertical, compact ? 11 : 14)
        .ampestraCard()
    }

    private var shouldShowRefresh: Bool {
        guard store.hasConfiguredSpeaker else { return false }
        return !store.connectionState.isConnected || store.lastError != nil
    }

    private var refreshAccessibilityLabel: String {
        store.connectionState.isConnected ? "Refresh speaker status" : "Reconnect to speaker"
    }

    private func refreshSpeaker() {
        if store.connectionState.isConnected {
            store.refreshNow()
        } else {
            store.reconnectNow()
        }
    }

    private var speakerIcon: String {
        store.speakerStatus == .standby ? "moon.stars.fill" : "hifispeaker.fill"
    }

    private var statusText: String {
        if store.connectionState == .connected, store.speakerStatus == .standby {
            return "Standby"
        }

        var parts = [store.connectionState.title]
        if shouldShowModel { parts.append(store.speakerModel) }
        return parts.joined(separator: " · ")
    }

    private var shouldShowModel: Bool {
        let model = normalizedIdentity(store.speakerModel)
        guard !model.isEmpty else { return false }
        return !normalizedIdentity(store.speakerName).contains(model)
    }

    private func normalizedIdentity(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

struct RemoteErrorBanner: View {
    @ObservedObject var store: RemoteStore

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 7) {
                Text("Connection problem")
                    .font(.subheadline.weight(.semibold))
                Text(store.lastError ?? "The speaker could not be reached.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if store.currentHost != nil {
                    Button("Try again", action: store.reconnectNow)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AmpestraTheme.accentBright)
                }
            }

            Spacer()

            Button(action: store.clearError) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss error")
        }
        .padding(16)
        .background(
            Color.orange.opacity(0.08),
            in: RoundedRectangle(
                cornerRadius: AmpestraTheme.cardCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(cornerRadius: AmpestraTheme.cardCornerRadius, style: .continuous)
                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
        }
    }
}

struct ChooseSpeakerCard: View {
    let chooseSpeaker: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            RemoteIcon(systemName: "hifispeaker.2.fill", size: 52)
            Text("Ready when your speaker is")
                .font(.headline)
            Text("Connect to a supported KEF speaker on your local network.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(action: chooseSpeaker) {
                Label("Choose a speaker", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
            }
            .ampestraGlassButton(prominent: true)
            .buttonBorderShape(.capsule)
            .tint(AmpestraTheme.accent)
        }
        .padding(22)
        .ampestraCard()
    }
}
