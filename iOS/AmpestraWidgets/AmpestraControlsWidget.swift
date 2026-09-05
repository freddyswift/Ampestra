import AppIntents
import SwiftUI
import WidgetKit

struct AmpestraControlsEntry: TimelineEntry {
    let date: Date
    let speakerName: String
    let volumeStep: Int
    let isConfigured: Bool
}

struct AmpestraControlsProvider: TimelineProvider {
    func placeholder(in context: Context) -> AmpestraControlsEntry {
        AmpestraControlsEntry(
            date: Date(),
            speakerName: "Living Room",
            volumeStep: 5,
            isConfigured: true
        )
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (AmpestraControlsEntry) -> Void
    ) {
        completion(context.isPreview ? placeholder(in: context) : currentEntry())
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<AmpestraControlsEntry>) -> Void
    ) {
        completion(Timeline(entries: [currentEntry()], policy: .never))
    }

    private func currentEntry() -> AmpestraControlsEntry {
        let speakerRecords = SpeakerRecordStore.shared
        let speaker = speakerRecords.defaultSpeaker()
        return AmpestraControlsEntry(
            date: Date(),
            speakerName: speaker?.displayName ?? "Speaker Controls",
            volumeStep: speakerRecords.preferredVolumeStep(),
            isConfigured: speaker != nil
        )
    }
}

struct AmpestraControlsWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: AmpestraControlsEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Spacer(minLength: 0)

            if entry.isConfigured {
                controls
            } else {
                Label("Connect a speaker in Ampestra", systemImage: "wifi.exclamationmark")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [Color.cyan.opacity(0.18), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "hifispeaker.2.fill")
                .font(.headline)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.cyan)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.speakerName)
                    .font(.headline)
                    .lineLimit(1)

                Text(entry.isConfigured ? "Volume step: \(entry.volumeStep)" : "Not configured")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: family == .systemSmall ? 8 : 12) {
            AmpestraWidgetActionButton(
                title: "Down",
                systemImage: "speaker.minus.fill",
                intent: LowerSpeakerVolumeWidgetIntent(),
                showsTitle: family == .systemMedium
            )

            AmpestraWidgetActionButton(
                title: "Up",
                systemImage: "speaker.plus.fill",
                intent: RaiseSpeakerVolumeWidgetIntent(),
                showsTitle: family == .systemMedium
            )

            AmpestraWidgetActionButton(
                title: "Mute",
                systemImage: "speaker.slash.fill",
                intent: MuteSpeakerWidgetIntent(),
                showsTitle: family == .systemMedium,
                role: .destructive
            )
        }
    }
}

private struct AmpestraWidgetActionButton<Intent: AppIntent>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let intent: Intent
    let showsTitle: Bool
    var role: ButtonRole?

    var body: some View {
        Button(intent: intent) {
            Group {
                if showsTitle {
                    Label(title, systemImage: systemImage)
                        .font(.caption.weight(.semibold))
                } else {
                    Image(systemName: systemImage)
                        .font(.body.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
        .background(.primary.opacity(0.08), in: .rect(cornerRadius: 12))
        .accessibilityLabel(Text(title))
    }
}

struct AmpestraControlsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: AmpestraWidgetConstants.controlsKind,
            provider: AmpestraControlsProvider()
        ) { entry in
            AmpestraControlsWidgetView(entry: entry)
        }
        .configurationDisplayName("Speaker Controls")
        .description("Turn the volume up or down using your chosen step, or mute your speaker.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct AmpestraWidgets: WidgetBundle {
    var body: some Widget {
        AmpestraControlsWidget()
    }
}
