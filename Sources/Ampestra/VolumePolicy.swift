import Foundation

/// Centralizes volume arithmetic so UI controls, media keys, and tests all use
/// the same clamping and step behavior.
///
/// KEF speakers expose volume as an integer from 0 through 100. The app can
/// either send every integer value or snap user input to a configured fixed
/// step. Keeping this logic outside `AppState` makes the behavior deterministic
/// and easy to validate without launching the macOS app.
struct VolumePolicy: Equatable, Sendable {
    static let allowedStepRange = 1...25

    var usesFixedSteps: Bool
    var stepSize: Int

    var clampedStepSize: Int {
        Self.clampedStepSize(stepSize)
    }

    static func clampedStepSize(_ stepSize: Int) -> Int {
        min(max(stepSize, allowedStepRange.lowerBound), allowedStepRange.upperBound)
    }

    func normalizedVolume(_ volume: Int) -> Int {
        let clampedVolume = Self.clampedVolume(volume)
        guard usesFixedSteps, clampedStepSize > 1 else { return clampedVolume }

        let roundedVolume = Int((Double(clampedVolume) / Double(clampedStepSize)).rounded()) * clampedStepSize
        return Self.clampedVolume(roundedVolume)
    }

    func nextVolume(from currentVolume: Int, direction: Int) -> Int {
        let direction = direction.signum()
        let clampedVolume = Self.clampedVolume(currentVolume)
        guard direction != 0 else { return clampedVolume }
        guard usesFixedSteps, clampedStepSize > 1 else {
            return Self.clampedVolume(clampedVolume + direction)
        }

        if direction > 0 {
            guard clampedVolume < 100 else { return 100 }
            return min(100, ((clampedVolume / clampedStepSize) + 1) * clampedStepSize)
        }

        guard clampedVolume > 0 else { return 0 }
        let previousStep = clampedVolume.isMultiple(of: clampedStepSize)
            ? clampedVolume - clampedStepSize
            : (clampedVolume / clampedStepSize) * clampedStepSize
        return max(0, previousStep)
    }

    static func muteToggle(from currentVolume: Int, restoreVolume: Int?) -> (targetVolume: Int, restoreVolume: Int?) {
        let clampedCurrentVolume = clampedVolume(currentVolume)
        if clampedCurrentVolume > 0 {
            return (targetVolume: 0, restoreVolume: clampedCurrentVolume)
        }

        guard let restoreVolume else {
            return (targetVolume: clampedCurrentVolume, restoreVolume: nil)
        }

        let clampedRestoreVolume = clampedVolume(restoreVolume)
        guard clampedRestoreVolume > 0 else {
            return (targetVolume: clampedCurrentVolume, restoreVolume: nil)
        }

        return (targetVolume: clampedRestoreVolume, restoreVolume: nil)
    }

    static func clampedVolume(_ volume: Int) -> Int {
        max(0, min(100, volume))
    }
}
