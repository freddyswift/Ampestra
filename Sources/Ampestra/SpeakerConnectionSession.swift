import Foundation

/// Mutable bookkeeping for one macOS connection and its polling loops.
/// AppState keeps the client identity guard shared with speaker actions; this
/// object owns the tasks and refresh coalescing that outlive an individual call.
@MainActor
final class SpeakerConnectionSession {
    var connectionTask: Task<Void, Never>?
    let pollingController = SpeakerPollingController()
    var isRefreshInProgress = false
    var needsTrailingRefresh = false
    var lastPlaybackStateRefresh: ContinuousClock.Instant?
    var consecutiveRefreshFailures = 0
}
