import SwiftUI

@main
struct AmpestraMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = RemoteStore()

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
