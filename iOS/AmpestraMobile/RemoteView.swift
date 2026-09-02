import KEFCore
import SwiftUI

struct RemoteView: View {
    @ObservedObject var store: RemoteStore
    @State private var presentedSheet: RemoteSheet?

    init(store: RemoteStore) {
        self.store = store

        #if DEBUG
        let initialSheet: RemoteSheet? = ProcessInfo.processInfo.arguments.contains("--demo-show-settings")
            ? .settings
            : nil
        _presentedSheet = State(initialValue: initialSheet)
        #else
        _presentedSheet = State(initialValue: nil)
        #endif
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let showsPlayback = store.speakerStatus == .powerOn
                    && store.hasConfiguredSpeaker
                    && store.nowPlaying != nil
                let compact = proxy.size.height < 690
                    || proxy.size.width < 370
                    || (showsPlayback && proxy.size.height < 900)

                ZStack {
                    AmpestraBackdrop()

                    VStack(spacing: compact ? 10 : 14) {
                        SpeakerOverviewCard(
                            store: store,
                            compact: compact,
                            chooseSpeaker: showConnection,
                            showSettings: showSettings
                        )

                        if store.lastError != nil {
                            RemoteErrorBanner(store: store)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        primaryControls(compact: compact)
                            .layoutPriority(1)

                        if showsPlayback {
                            PlaybackControlCard(store: store, compact: compact)
                        }

                        if store.speakerStatus == .powerOn, store.hasConfiguredSpeaker {
                            Spacer(minLength: compact ? 4 : 8)

                            SpeakerActionsRow(store: store, compact: compact)
                        } else if !store.hasConfiguredSpeaker {
                            ChooseSpeakerCard(chooseSpeaker: showConnection)
                        }
                    }
                    .frame(maxWidth: 540, maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, compact ? 14 : 18)
                    .padding(.top, compact ? 4 : 8)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(AmpestraTheme.accent)
        .background(alignment: .topLeading) {
            volumeCaptureView
        }
        .sheet(item: $presentedSheet, content: sheetContent)
        .onAppear(perform: presentSetupIfNeeded)
        .onChange(of: store.connectionState, connectionStateChanged)
        .animation(.easeInOut(duration: 0.2), value: store.lastError)
        .animation(.easeInOut(duration: 0.2), value: store.notice)
    }

    @ViewBuilder
    private func primaryControls(compact: Bool) -> some View {
        if store.connectionState == .connected, store.speakerStatus != .powerOn {
            StandbyControlCard(store: store, compact: compact)
                .frame(maxHeight: .infinity)
        } else if store.hasConfiguredSpeaker {
            VolumeControlCard(store: store, compact: compact)
        }
    }

    private var volumeCaptureView: some View {
        SystemVolumeCaptureView(controller: store.hardwareButtons)
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func sheetContent(_ destination: RemoteSheet) -> some View {
        switch destination {
        case .connection:
            ConnectionView(store: store)
        case .settings:
            MobileSettingsView(store: store, changeSpeaker: beginSpeakerChange)
        }
    }

    private func showConnection() {
        presentedSheet = .connection
    }

    private func showSettings() {
        presentedSheet = .settings
    }

    private func beginSpeakerChange() {
        presentedSheet = nil
        DispatchQueue.main.async { presentedSheet = .connection }
    }

    private func presentSetupIfNeeded() {
        guard !store.hasConfiguredSpeaker else { return }
        presentedSheet = .connection
    }

    private func connectionStateChanged(
        _ oldValue: SpeakerConnectionState,
        _ newValue: SpeakerConnectionState
    ) {
        guard newValue == .connected, presentedSheet == .connection else { return }
        presentedSheet = nil
    }

}

private enum RemoteSheet: String, Identifiable {
    case connection
    case settings

    var id: String { rawValue }
}
