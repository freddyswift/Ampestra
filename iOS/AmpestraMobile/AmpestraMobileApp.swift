import AppIntents
import SwiftUI

@main
struct AmpestraMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store: RemoteStore

    init() {
        let speakerRecords = SpeakerRecordStore.shared
        let speakerCommands = SpeakerCommandService(speakerRecords: speakerRecords)

        AppDependencyManager.shared.add(dependency: speakerRecords)
        AppDependencyManager.shared.add(dependency: speakerCommands)
        AmpestraShortcuts.updateAppShortcutParameters()

        _store = StateObject(
            wrappedValue: RemoteStore(speakerRecords: speakerRecords)
        )
    }

    var body: some Scene {
        WindowGroup {
            RemoteView(store: store)
                .onChange(of: scenePhase, initial: true) { _, newPhase in
                    store.setAppActive(
                        newPhase == .active,
                        mutePhoneOnStop: newPhase == .background
                    )
                }
        }
    }
}
