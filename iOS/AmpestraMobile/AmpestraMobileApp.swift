import AppIntents
import SwiftUI
import UIKit
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
                // Start the restore before SwiftUI renders the inactive phase,
                // while the native volume control is still in the active scene.
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                    store.setScenePhase(.inactive)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    store.setScenePhase(.active)
                }
                .onChange(of: scenePhase, initial: true) { _, newPhase in
                    store.setScenePhase(newPhase)
                }
        }
    }
}
