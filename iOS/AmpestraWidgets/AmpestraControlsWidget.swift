import AppIntents
import SwiftUI
import WidgetKit

struct AmpestraControlsEntry: TimelineEntry {
    let date: Date
    let speakerName: String
    let volumeStep: Int
    let isConfigured: Bool
    var reading: WidgetSpeakerReading? = nil
}

struct AmpestraControlsProvider: TimelineProvider {
    func placeholder(in context: Context) -> AmpestraControlsEntry {
        AmpestraControlsEntry(
            date: Date(),
            speakerName: "Living Room",
            volumeStep: 5,
            isConfigured: true,
            reading: .init(volume: 42, isPoweredOn: true, updatedAt: Date())
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
            isConfigured: speaker != nil && speaker?.requiresReconfirmation != true,
            reading: speaker?.requiresReconfirmation == true ? nil : speaker?.widgetReading
        )
    }
}

struct AmpestraControlsWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: AmpestraControlsEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if entry.isConfigured {
                volumeReading
                Spacer(minLength: 0)
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

            }
        }
    }

    private var volumeReading: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(entry.reading.map { $0.isPoweredOn ? "\($0.volume)" : "—" } ?? "—")
                        .font(.system(size: family == .systemSmall ? 30 : 32, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(entry.reading.map { !$0.isPoweredOn ? "Unavailable" : ($0.volume == 0 ? "Muted" : "/ 100") } ?? "Volume")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                if let reading = entry.reading {
                    HStack(spacing: 3) {
                        Text("Last known")
                        Text(reading.updatedAt, style: .relative)
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityLabel(Text("Last updated \(reading.updatedAt.formatted())"))
                } else {
                    Text("Open app to sync")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            if family == .systemMedium {
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Text("VOLUME STEP").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text("±\(entry.volumeStep)").font(.title3.weight(.semibold).monospacedDigit())
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            AmpestraWidgetActionButton(
                title: "Down",
                systemImage: "minus",
                intent: LowerSpeakerVolumeWidgetIntent(),
                showsTitle: family == .systemMedium
            )

            AmpestraWidgetActionButton(
                title: "Mute",
                systemImage: "speaker.slash.fill",
                intent: MuteSpeakerWidgetIntent(),
                showsTitle: family == .systemMedium,
                highlighted: entry.reading?.isPoweredOn == true && entry.reading?.volume == 0
            )

            AmpestraWidgetActionButton(
                title: "Up",
                systemImage: "plus",
                intent: RaiseSpeakerVolumeWidgetIntent(),
                showsTitle: family == .systemMedium
            )
        }
    }
}

private struct AmpestraWidgetActionButton<Intent: AppIntent>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let intent: Intent
    let showsTitle: Bool
    var highlighted = false

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
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(highlighted ? Color.cyan : Color.primary)
        .background(highlighted ? Color.cyan.opacity(0.18) : Color.primary.opacity(0.07), in: .rect(cornerRadius: 14))
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
        .description("See the last known volume, adjust it by your chosen step, or mute your speaker.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct AmpestraWidgets: WidgetBundle {
    var body: some Widget {
        AmpestraControlsWidget()
    }
}

#Preview("Small", as: .systemSmall) {
    AmpestraControlsWidget()
} timeline: {
    AmpestraControlsEntry(date: Date(), speakerName: "Living Room", volumeStep: 5, isConfigured: true,
                         reading: .init(volume: 42, isPoweredOn: true, updatedAt: Date()))
    AmpestraControlsEntry(date: Date(), speakerName: "Living Room", volumeStep: 5, isConfigured: true)
    AmpestraControlsEntry(date: Date(), speakerName: "Ampestra", volumeStep: 5, isConfigured: false)
}

#Preview("Medium", as: .systemMedium) {
    AmpestraControlsWidget()
} timeline: {
    AmpestraControlsEntry(date: Date(), speakerName: "Living Room", volumeStep: 7, isConfigured: true,
                         reading: .init(volume: 42, isPoweredOn: true, updatedAt: Date()))
    AmpestraControlsEntry(date: Date(), speakerName: "Living Room", volumeStep: 7, isConfigured: true,
                         reading: .init(volume: 0, isPoweredOn: true, updatedAt: Date()))
    AmpestraControlsEntry(date: Date(), speakerName: "Living Room", volumeStep: 7, isConfigured: true,
                         reading: .init(volume: 42, isPoweredOn: false, updatedAt: Date()))
}
