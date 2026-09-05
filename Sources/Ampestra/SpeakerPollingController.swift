import Foundation

/// Owns the long-running refresh loops for the currently connected speaker.
///
/// `AppState` still decides what the refreshed state means, but this object is
/// responsible for task lifetime. That separation keeps cancellation rules in
/// one place: starting polling cancels previous polling, and disconnecting calls
/// `stop()` to cancel every background loop.
@MainActor
final class SpeakerPollingController {
    private var pollTask: Task<Void, Never>?
    private var playbackStateTask: Task<Void, Never>?

    deinit {
        pollTask?.cancel()
        playbackStateTask?.cancel()
    }

    func start(
        refresh: @escaping @MainActor () async -> Void,
        isPlaybackStatePollingNeeded: @escaping @MainActor () -> Bool,
        refreshPlaybackStateForVolumeRouting: @escaping @MainActor () async -> Void
    ) {
        stop()

        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                await refresh()
            }
        }

        playbackStateTask = Task { @MainActor in
            while !Task.isCancelled {
                let pollingIsNeeded = isPlaybackStatePollingNeeded()
                try? await Task.sleep(for: pollingIsNeeded ? .milliseconds(750) : .seconds(3))
                guard !Task.isCancelled else { break }
                guard pollingIsNeeded else { continue }
                await refreshPlaybackStateForVolumeRouting()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        playbackStateTask?.cancel()
        playbackStateTask = nil
    }
}
