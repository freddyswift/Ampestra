import Foundation

/// All app-hosted control surfaces use this queue, keyed by saved speaker ID.
/// A lock spans the complete read/modify/write operation, including suspension.
actor SpeakerCommandQueue {
    static let shared = SpeakerCommandQueue()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private struct PendingVolume {
        let value: Int
        let expires: ContinuousClock.Instant
    }
    private var owners = Set<String>()
    private var waiters: [String: [Waiter]] = [:]
    private var volumes: [String: PendingVolume] = [:]

    func run<Value: Sendable>(
        speakerID: String,
        operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire(speakerID)
        defer { release(speakerID) }
        try Task.checkCancellation()
        return try await operation()
    }

    func rememberVolume(_ volume: Int, speakerID: String) {
        volumes = volumes.filter { $0.value.expires > .now }
        volumes[speakerID] = PendingVolume(value: volume, expires: .now + .seconds(5))
    }

    func reconciledVolume(_ observed: Int, speakerID: String) -> Int {
        guard let pending = volumes[speakerID] else { return observed }
        if pending.expires <= .now || pending.value == observed {
            volumes[speakerID] = nil
            return observed
        }
        return pending.value
    }

    func clearVolume(speakerID: String) {
        volumes[speakerID] = nil
    }

    private func acquire(_ key: String) async throws {
        try Task.checkCancellation()
        if owners.insert(key).inserted { return }
        guard waiters[key, default: []].count < 64 else {
            throw SpeakerCommandError.commandQueueFull
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[key, default: []].append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id, key: key) }
        }
    }

    private func cancelWaiter(_ id: UUID, key: String) {
        guard let index = waiters[key]?.firstIndex(where: { $0.id == id }),
              let waiter = waiters[key]?.remove(at: index) else { return }
        waiter.continuation.resume(throwing: CancellationError())
        if waiters[key]?.isEmpty == true { waiters[key] = nil }
    }

    private func release(_ key: String) {
        if var queued = waiters[key], !queued.isEmpty {
            let next = queued.removeFirst()
            waiters[key] = queued.isEmpty ? nil : queued
            next.continuation.resume()
        } else {
            owners.remove(key)
        }
    }
}
