import Foundation

enum AmpestraSharedDefaults {
    static let appGroupIdentifier = "group.com.freddyswift.ampestra"
    static let migrationKey = "ios.sharedDefaultsMigration.v1"

    static let shared: UserDefaults =
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard

    /// Moves existing app-only preferences into the App Group on first launch
    /// after widgets are installed. Existing shared values always win.
    @discardableResult
    static func migrateFromStandardDefaultsIfNeeded(
        from source: UserDefaults = .standard,
        to destination: UserDefaults = shared
    ) -> Bool {
        guard !destination.bool(forKey: migrationKey) else { return false }

        for key in SpeakerPreferenceKeys.allPersistedKeys
        where destination.object(forKey: key) == nil {
            guard let value = source.object(forKey: key) else { continue }
            destination.set(value, forKey: key)
        }

        destination.set(true, forKey: migrationKey)
        return true
    }
}

enum AmpestraWidgetConstants {
    static let controlsKind = "com.freddyswift.ampestra.speaker-controls"
}
