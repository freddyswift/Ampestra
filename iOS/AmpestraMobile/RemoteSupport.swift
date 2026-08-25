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

@MainActor
final class VolumeCommandDispatcher {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let debounce: Duration
    private let sleep: Sleep
    private var task: Task<Void, Never>?
    private var pendingVolume: Int?
    private weak var activeSpeaker: KEFSpeakerClient?
    private var generation = 0

    init(
        debounce: Duration = .milliseconds(85),
        sleep: @escaping Sleep = { duration in try await Task.sleep(for: duration) }
    ) {
        self.debounce = debounce
        self.sleep = sleep
    }

    func submit(
        _ volume: Int,
        to speaker: KEFSpeakerClient,
        completion: @escaping @MainActor (Result<Int, Error>) -> Void
    ) {
        if activeSpeaker !== speaker {
            cancel()
            activeSpeaker = speaker
        }

        pendingVolume = VolumePolicy.clampedVolume(volume)
        guard task == nil else { return }

        generation += 1
        let currentGeneration = generation
        task = Task { @MainActor [weak self, weak speaker] in
            guard let self, let speaker else { return }
            defer {
                if self.generation == currentGeneration {
                    self.task = nil
                    self.activeSpeaker = nil
                }
            }

            while !Task.isCancelled {
                guard let requestedVolume = self.pendingVolume else { return }
                self.pendingVolume = nil

                do {
                    try await self.sleep(self.debounce)
                    if self.pendingVolume != nil { continue }

                    try await speaker.setVolume(requestedVolume)
                    if self.pendingVolume == nil {
                        completion(.success(requestedVolume))
                    }
                } catch is CancellationError {
                    return
                } catch {
                    if self.pendingVolume == nil {
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    func cancel() {
        generation += 1
        pendingVolume = nil
        activeSpeaker = nil
        task?.cancel()
        task = nil
    }
}
