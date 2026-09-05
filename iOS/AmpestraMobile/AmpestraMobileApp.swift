import AppIntents
import SwiftUI
import WidgetKit

@main
struct AmpestraMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store: RemoteStore

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo-saved-speakers") {
            _store = StateObject(wrappedValue: RemoteStore())
            return
        }
        #endif
        if AmpestraSharedDefaults.migrateFromStandardDefaultsIfNeeded() {
            WidgetCenter.shared.reloadTimelines(ofKind: AmpestraWidgetConstants.controlsKind)
        }
        let defaults = AmpestraSharedDefaults.shared
        let speakerRecords = SpeakerRecordStore.shared
        let speakerCommands = SpeakerCommandService(speakerRecords: speakerRecords)

        AppDependencyManager.shared.add(dependency: speakerRecords)
        AppDependencyManager.shared.add(dependency: speakerCommands)
        AmpestraShortcuts.updateAppShortcutParameters()

        _store = StateObject(
            wrappedValue: RemoteStore(
                defaults: defaults,
                speakerRecords: speakerRecords
            )
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
