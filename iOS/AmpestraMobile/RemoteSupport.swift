import Foundation
import KEFCore
import UIKit

@MainActor
enum RemoteHaptics {
    static func controlImpact() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred(intensity: 0.72)
    }

    static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }
}

enum VolumeHapticPolicy {
    private static let landmarks = [0, 50, 100]

    static func crossesLandmark(from previous: Int, to current: Int) -> Bool {
        guard previous != current else { return false }

        if current > previous {
            return landmarks.contains { previous < $0 && current >= $0 }
        }

        return landmarks.contains { previous > $0 && current <= $0 }
    }
}

enum SpeakerConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(message: String)

    var title: String {
        switch self {
        case .disconnected:
            "Not connected"
        case .connecting:
            "Connecting"
        case .connected:
            "Connected"
        case .reconnecting:
            "Reconnecting"
        case .failed:
            "Connection issue"
        }
    }

    var isConnected: Bool {
        self == .connected
    }

    var isWorking: Bool {
        switch self {
        case .connecting, .reconnecting:
            true
        default:
            false
        }
    }
}
struct ReconnectPolicy: Equatable {
    var delays: [Duration] = [
        .milliseconds(500),
        .seconds(1),
        .seconds(2),
        .seconds(4),
        .seconds(8),
        .seconds(15),
    ]

    func delay(afterFailure failureCount: Int) -> Duration {
        guard !delays.isEmpty else { return .zero }
        let index = min(max(0, failureCount - 1), delays.count - 1)
        return delays[index]
    }
}

enum VolumeButtonDirection: Int, Equatable {
    case down = -1
    case up = 1
}

struct OutputVolumeChangeInterpreter {
    private(set) var previousVolume: Float
    private let epsilon: Float

    init(initialVolume: Float, epsilon: Float = 0.0001) {
        previousVolume = Self.clamped(initialVolume)
        self.epsilon = epsilon
    }

    mutating func reset(to volume: Float) {
        previousVolume = Self.clamped(volume)
    }

    mutating func direction(for volume: Float) -> VolumeButtonDirection? {
        let volume = Self.clamped(volume)
        defer { previousVolume = volume }

        let delta = volume - previousVolume
        if delta > epsilon { return .up }
        if delta < -epsilon { return .down }
        return nil
    }

    static func shouldRecenter(_ volume: Float) -> Bool {
        volume <= 0.25 || volume >= 0.75
    }

    static func clamped(_ volume: Float) -> Float {
        min(1, max(0, volume))
    }
}
