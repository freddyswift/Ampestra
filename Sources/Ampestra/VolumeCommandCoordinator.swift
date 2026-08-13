import Foundation

@MainActor
final class VolumeCommandCoordinator {
    private var task: Task<Void, Never>?
    private var pendingVolume: Int?
    private var activeSpeaker: KEFSpeakerClient?
    private var generation = 0

    func submit(
        volume: Int,
        speaker: KEFSpeakerClient,
        timing: SpeakerTimingPolicy,
        didSendLatest: @escaping @MainActor (KEFSpeakerClient) async -> Void,
        didFailLatest: @escaping @MainActor (Error, KEFSpeakerClient) async -> Void
    ) {
        if activeSpeaker !== speaker {
            cancel()
            activeSpeaker = speaker
        }

        pendingVolume = volume

        guard task == nil else { return }

        generation += 1
        let taskGeneration = generation
        task = Task { @MainActor in
            defer {
                if generation == taskGeneration {
                    task = nil
                    activeSpeaker = nil
                }
            }

            while !Task.isCancelled {
                guard let requestedVolume = pendingVolume else {
                    return
                }
                pendingVolume = nil

                do {
                    try await timing.sleep(timing.volumeCommandCoalescingWindow)

                    if pendingVolume != nil {
                        continue
                    }

                    try await speaker.setVolume(requestedVolume)

                    if pendingVolume != nil {
                        continue
                    }

                    try await timing.sleep(timing.postVolumeRefreshDelay)

                    if pendingVolume == nil {
                        await didSendLatest(speaker)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    if pendingVolume == nil {
                        await didFailLatest(error, speaker)
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
