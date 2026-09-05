import Foundation

enum SpeakerPreferenceKeys {
    static let savedSpeakers = "ios.savedSpeakers.v2"
    static let defaultSpeakerID = "ios.defaultSpeakerID.v2"

    // Legacy single-speaker keys. `SpeakerRecordStore` consumes and removes
    // these during its one-way migration to stable speaker records.
    static let savedHost = "ios.savedSpeakerHost"
    static let savedMACAddress = "ios.savedSpeakerMACAddress"
    static let manualHost = "ios.manualSpeakerHost"
    static let hardwareButtonsEnabled = "ios.hardwareButtonsEnabled"
    static let mutePhoneOnExit = "ios.mutePhoneOnExit"
    static let volumeStep = "ios.volumeStep"

    static let allPersistedKeys = [
        savedSpeakers,
        defaultSpeakerID,
        savedHost,
        savedMACAddress,
        manualHost,
        hardwareButtonsEnabled,
        mutePhoneOnExit,
        volumeStep,
    ]
}
