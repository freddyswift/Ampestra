import AppIntents
import SwiftUI
import WidgetKit

struct AmpestraControlsEntry: TimelineEntry {
    let date: Date
    let speakerName: String
    let volumeStep: Int
    let isConfigured: Bool
    var reading: WidgetSpeakerReading? = nil
    var speakerID: String? = nil
    var refreshFailed = false
}

struct AmpestraControlsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> AmpestraControlsEntry {
        AmpestraControlsEntry(
            date: Date(),
            speakerName: "Living Room",
            volumeStep: 5,
            isConfigured: true,
            reading: .init(volume: 42, isPoweredOn: true, updatedAt: Date())
        )
    }

    func snapshot(for configuration: SelectWidgetSpeakerIntent, in context: Context) async -> AmpestraControlsEntry {
        if context.isPreview { return placeholder(in: context) }
        return await refreshedEntry(configuration: configuration)
    }

    func timeline(for configuration: SelectWidgetSpeakerIntent, in context: Context) async -> Timeline<AmpestraControlsEntry> {
        let entry = await refreshedEntry(configuration: configuration)
        return Timeline(entries: [entry], policy: .after(
            entry.date.addingTimeInterval(WidgetSpeakerRefreshService.refreshInterval)
        ))
    }

    private func refreshedEntry(configuration: SelectWidgetSpeakerIntent) async -> AmpestraControlsEntry {
        let refreshed = await WidgetSpeakerRefreshService().refresh(configuration: configuration)
        let speakerRecords = SpeakerRecordStore.shared
        let speaker = configuration.selectedSpeaker(in: speakerRecords)
        return AmpestraControlsEntry(
            date: Date(),
            speakerName: speaker?.displayName ?? configuration.speaker?.name ?? "Speaker Controls",
            volumeStep: speakerRecords.preferredVolumeStep(),
            isConfigured: speaker != nil && speaker?.requiresReconfirmation != true,
            reading: speaker?.requiresReconfirmation == true ? nil
                : (speaker?.id == refreshed.speakerID ? refreshed.reading : speaker?.widgetReading),
            speakerID: speaker?.id ?? configuration.speaker?.id,
            refreshFailed: speaker?.id != refreshed.speakerID || refreshed.refreshFailed
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
                Label(entry.speakerID == nil ? "Connect a speaker in Ampestra" : "Reconnect in Ampestra or edit this widget", systemImage: "wifi.exclamationmark")
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
        HStack(spacing: 6) {
            Image(systemName: "hifispeaker.2.fill")
                .font(.headline)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.cyan)

            Text(entry.speakerName)
                .font(family == .systemSmall ? .caption.weight(.semibold) : .headline)
                .lineLimit(1)
            Spacer(minLength: 0)
            if entry.isConfigured {
                Button(intent: RefreshSpeakerWidgetIntent(speakerID: entry.speakerID)) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh speaker")
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
                    Text(entry.reading.map { !$0.isPoweredOn ? "Standby" : ($0.volume == 0 ? "Muted" : "/ 100") } ?? "Volume")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                if let reading = entry.reading {
                    HStack(spacing: 3) {
                        Text(entry.refreshFailed ? "Offline ·" : "Synced")
                        Text(reading.updatedAt, style: .relative)
                            .lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Last synced \(reading.updatedAt.formatted()). \(entry.refreshFailed ? "Speaker unreachable." : "")")
                } else {
                    Text(entry.refreshFailed ? "Can't reach speaker" : "Tap refresh to sync")
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
                intent: LowerSpeakerVolumeWidgetIntent(speakerID: entry.speakerID),
                showsTitle: family == .systemMedium
            )

            AmpestraWidgetActionButton(
                title: entry.reading?.volume == 0 ? "Unmute" : "Mute",
                systemImage: entry.reading?.volume == 0 ? "speaker.wave.2.fill" : "speaker.slash.fill",
                intent: MuteSpeakerWidgetIntent(speakerID: entry.speakerID),
                showsTitle: family == .systemMedium,
                highlighted: entry.reading?.isPoweredOn == true && entry.reading?.volume == 0
            )

            AmpestraWidgetActionButton(
                title: "Up",
                systemImage: "plus",
                intent: RaiseSpeakerVolumeWidgetIntent(speakerID: entry.speakerID),
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
        .background(highlighted ? Color.cyan.opacity(0.18) : Color.primary.opacity(0.07), in: AmpestraShapes.control)
        .accessibilityLabel(Text(title))
    }
}

struct AmpestraControlsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: AmpestraWidgetConstants.controlsKind,
            intent: SelectWidgetSpeakerIntent.self,
            provider: AmpestraControlsProvider()
        ) { entry in
            AmpestraControlsWidgetView(entry: entry)
        }
        .configurationDisplayName("Speaker Controls")
        .description("See speaker volume, adjust it, toggle mute, or refresh directly from your Home Screen.")
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
