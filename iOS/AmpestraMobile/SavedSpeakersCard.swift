import KEFCore
import SwiftUI

struct SavedSpeakersCard: View {
    @ObservedObject var store: RemoteStore
    let discoveredSpeakers: [DiscoveredSpeaker]

    var body: some View {
        if !store.savedSpeakers.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                SectionLabel(title: "Saved speakers")
                Text("Switch speakers even when they don’t appear in a scan.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(store.savedSpeakers) { speaker in
                    SavedSpeakerRow(
                        speaker: speaker,
                        isSelected: store.currentSpeakerID == speaker.id,
                        isConnected: store.currentSpeakerID == speaker.id && store.connectionState == .connected,
                        isDefault: store.defaultSpeakerID == speaker.id,
                        isNearby: discoveredSpeakers.contains { $0.host == speaker.host },
                        isWorking: store.connectionState == .connecting,
                        connect: { store.connect(to: speaker) },
                        makeDefault: { store.makeDefaultSpeaker(id: speaker.id) }
                    )
                }
                if let error = store.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("The default is used by Siri and widgets without a selected speaker. Widgets assigned to a specific speaker keep that speaker.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .ampestraCard()
        }
    }
}

private struct SavedSpeakerRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let speaker: SavedSpeaker
    let isSelected: Bool
    let isConnected: Bool
    let isDefault: Bool
    let isNearby: Bool
    let isWorking: Bool
    let connect: () -> Void
    let makeDefault: () -> Void

    private var status: String {
        if speaker.requiresReconfirmation == true || speaker.model.isEmpty {
            return "Reconnect using discovery or a manual address to confirm identity"
        }
        if isConnected { return "Connected" }
        if isSelected { return "Selected · Offline" }
        return isNearby ? "Nearby" : "Not discovered · May be offline"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: connect) {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                    : AnyLayout(HStackLayout(spacing: 12))
                layout {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "hifispeaker.fill")
                        .foregroundStyle(AmpestraTheme.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(speaker.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    if isDefault {
                        Text("Default")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("saved-speaker-\(speaker.displayName)")
            .disabled(isWorking || isConnected)
            .accessibilityLabel("\(speaker.displayName), \(status)\(isDefault ? ", default speaker" : "")")

            if !isDefault {
                Button("Make default", action: makeDefault)
                    .font(.caption.weight(.semibold))
                    .disabled(speaker.requiresReconfirmation == true || speaker.model.isEmpty)
                    .accessibilityLabel("Make \(speaker.displayName) the default speaker")
            }
        }
        .padding(12)
        .background(AmpestraTheme.control, in: RoundedRectangle(cornerRadius: AmpestraTheme.nestedCornerRadius))
    }
}
