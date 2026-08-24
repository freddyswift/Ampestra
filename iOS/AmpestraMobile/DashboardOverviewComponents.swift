import SwiftUI

struct SpeakerOverviewCard: View {
    @ObservedObject var store: RemoteStore
    let compact: Bool
    let chooseSpeaker: () -> Void

    var body: some View {
        HStack(spacing: compact ? 10 : 14) {
            Button(action: chooseSpeaker) {
                HStack(spacing: compact ? 10 : 14) {
                    RemoteIcon(systemName: speakerIcon, size: compact ? 40 : 48)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.speakerName)
                            .font(compact ? .headline : .title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        HStack(spacing: 7) {
                            ConnectionDot(state: store.connectionState)
                            Text(statusText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens speaker connection options")

            if store.connectionState.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .tint(AmpestraTheme.accentBright)
            } else if store.hasConfiguredSpeaker {
                Button(action: store.refreshNow) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                }
                .ampestraGlassButton()
                .buttonBorderShape(.circle)
                .foregroundStyle(.secondary)
                .disabled(store.connectionState != .connected)
                .accessibilityLabel("Refresh speaker status")
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(compact ? 13 : 18)
        .ampestraCard()
    }

    private var speakerIcon: String {
        store.speakerStatus == .standby ? "moon.stars.fill" : "hifispeaker.fill"
    }

    private var statusText: String {
        var parts = [store.connectionState.title]
        if !store.speakerModel.isEmpty { parts.append(store.speakerModel) }
        if store.connectionState == .connected, store.speakerStatus == .standby { parts.append("Standby") }
        return parts.joined(separator: " · ")
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
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
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
        .ampestraCard(cornerRadius: 24)
    }
}
