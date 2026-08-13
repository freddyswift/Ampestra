import Foundation

struct SpeakerTimingPolicy {
    var autoDiscoveryTimeout: Duration
    var autoDiscoveryPollInterval: Duration
    var connectionRetryDelays: [Duration]
    var stateRefreshPollInterval: Duration
    var pendingVolumeRetention: Duration
    var volumeCommandCoalescingWindow: Duration
    var postVolumeRefreshDelay: Duration
    var sourceVolumeSettleDelay: Duration
    var trackRefreshDelay: Duration
    var wakePollInterval: Duration
    var wakeAttemptCount: Int
    var sleep: @Sendable (Duration) async throws -> Void

    static let live = SpeakerTimingPolicy(
        autoDiscoveryTimeout: .seconds(14),
        autoDiscoveryPollInterval: .milliseconds(500),
        connectionRetryDelays: [.milliseconds(500), .seconds(1), .seconds(2)],
        stateRefreshPollInterval: .milliseconds(400),
        pendingVolumeRetention: .seconds(5),
        volumeCommandCoalescingWindow: .milliseconds(80),
        postVolumeRefreshDelay: .milliseconds(400),
        sourceVolumeSettleDelay: .milliseconds(500),
        trackRefreshDelay: .milliseconds(500),
        wakePollInterval: .seconds(1),
        wakeAttemptCount: 20,
        sleep: { duration in
            try await Task.sleep(for: duration)
        }
    )

    func connectionRetryDelay(afterAttempt attempt: Int) -> Duration {
        guard !connectionRetryDelays.isEmpty else {
            return .seconds(0)
        }

        return connectionRetryDelays[min(attempt, connectionRetryDelays.count - 1)]
    }
}
