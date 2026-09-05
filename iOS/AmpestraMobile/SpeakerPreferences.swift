import Foundation
import KEFCore

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
    static let snapVolumeSteps = "ios.snapVolumeSteps"
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
        snapVolumeSteps,
    ]
}

/// Button snapping is available only for steps that divide the full volume range evenly.
enum MobileVolumeStepPolicy {
    static func supportsSnapping(step: Int) -> Bool {
        VolumePolicy.allowedStepRange.contains(step) && 100.isMultiple(of: step)
    }

    static func target(from volume: Int, amount: Int, snap: Bool) -> Int {
        let amount = min(100, max(-100, amount))
        if snap && supportsSnapping(step: abs(amount)) {
            return VolumePolicy(usesFixedSteps: true, stepSize: abs(amount))
                .nextVolume(from: volume, direction: amount)
        }
        return VolumePolicy.clampedVolume(VolumePolicy.clampedVolume(volume) + amount)
    }
}
