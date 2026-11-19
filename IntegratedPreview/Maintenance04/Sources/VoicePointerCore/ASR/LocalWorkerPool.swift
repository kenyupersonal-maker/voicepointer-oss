// I03C Local worker lease pool.
// Serialized lifecycle: a single `transitioning` gate guards every awaited
// shutdown/start so no stale completion can clear or shutdown a newer lease.
import Foundation

internal actor LocalWorkerPool {
    internal typealias Factory = @Sendable (String, String) -> any BetaInferenceClient

    private struct Lease {
        let client: any BetaInferenceClient
        let profileID: String
        let language: String
    }

    private let idleNanoseconds: UInt64
    private let factory: Factory

    var isClosed: Bool { closed }
    var hasPendingRelease: Bool { pendingRelease != nil }
    private var closed = false
    private var owner: UUID?
    private var cached: Lease?
    private var generation: UInt64 = 0
    private var transitioning = false
    private var pendingRelease: (id: UUID, discard: Bool)?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var idleTask: Task<Void, Never>?

    internal init(idleNanoseconds: UInt64 = 90_000_000_000,
                 factory: @escaping Factory = { BetaWorkerClient(profileID: $0, language: $1) }) {
        self.idleNanoseconds = idleNanoseconds
        self.factory = factory
    }

    internal func acquire(id: UUID, profileID: String, language: String, background: Bool = false) async throws -> any BetaInferenceClient {
        try Task.checkCancellation()
        if closed { throw BetaWorkerTransportError(description: "pool closed") }
        if transitioning { throw BetaWorkerTransportError(description: "pool is transitioning") }
        // Any active owner — even the same UUID — blocks new acquisition; the
        // current owner must release before switching routes.
        if owner != nil { throw BetaWorkerTransportError(description: "pool busy for active owner") }
        if let lease = cached, lease.profileID == profileID, lease.language == language {
            idleTask?.cancel(); idleTask = nil
            owner = id
            return lease.client
        }
        // Reserve owner and transition before any await.
        owner = id
        transitioning = true
        idleTask?.cancel(); idleTask = nil
        let gen = generation
        let old = cached
        cached = nil
        if let old { await old.client.shutdown() }
        let client = factory(profileID, language)
        if background { await client.prepareBackgroundPriority() }
        do {
            try await client.start()
            try Task.checkCancellation()
        } catch {
            await client.shutdown()
            if generation == gen, owner == id {
                owner = nil
                pendingRelease = nil
            }
            finishTransition()
            throw error
        }
        return try await commit(gen: gen, own: id, client: client,
                                profileID: profileID, language: language)
    }

    /// Refuses any foreground owner/transition immediately. Does not queue behind or preempt foreground work.
    internal func acquireBackground(id: UUID, profileID: String, language: String) async throws -> any BetaInferenceClient {
        guard !closed, !transitioning, owner == nil else { throw BetaWorkerTransportError(description: "background unavailable") }
        return try await acquire(id: id, profileID: profileID, language: language, background: true)
    }

    private func commit(gen: UInt64, own: UUID, client: any BetaInferenceClient,
                        profileID: String, language: String) async throws -> any BetaInferenceClient {
        if generation != gen || owner != own {
            // Invalidation (shutdownAll / route teardown) happened during start.
            await client.shutdown()
            finishTransition()
            throw CancellationError()
        }
        if let pending = pendingRelease, pending.id == own {
            // Release (or shutdownAll) requested while start was in flight:
            // never hand out a live lease, discard regardless of keepwarm.
            pendingRelease = nil
            generation &+= 1
            await client.shutdown()
            owner = nil
            cached = nil
            finishTransition()
            throw CancellationError()
        }
        cached = Lease(client: client, profileID: profileID, language: language)
        finishTransition()
        return client
    }

    internal func release(id: UUID, discard: Bool) async {
        if owner != id { return } // unknown or non-owner id: no-op
        while transitioning {
            // Merge with OR: a later keepwarm cannot weaken a concurrent discard.
            if let p = pendingRelease, p.id == id {
                pendingRelease = (id, p.discard || discard)
            } else {
                pendingRelease = (id, discard)
            }
            await withCheckedContinuation { waiters.append($0) }
        }
        guard owner == id else { return }
        if discard {
            transitioning = true
            idleTask?.cancel(); idleTask = nil
            generation &+= 1
            let lease = cached
            cached = nil
            owner = nil
            if let lease { await lease.client.shutdown() }
            finishTransition()
        } else {
            generation &+= 1
            owner = nil
            scheduleIdleExpiry()
        }
    }

    internal func shutdownAll() async {
        // Permanent close is set synchronously before any await; no later
        // acquire can ever return a lease after shutdownAll.
        closed = true
        if let own = owner {
            if let p = pendingRelease, p.id == own {
                pendingRelease = (own, p.discard || true)
            } else {
                pendingRelease = (own, true)
            }
        }
        while transitioning {
            await withCheckedContinuation { waiters.append($0) }
        }
        guard cached != nil || owner != nil else { return }
        transitioning = true
        idleTask?.cancel(); idleTask = nil
        generation &+= 1
        let lease = cached
        cached = nil
        owner = nil
        pendingRelease = nil
        if let lease { await lease.client.shutdown() }
        finishTransition()
    }

    private func scheduleIdleExpiry() {
        let gen = generation
        let delay = idleNanoseconds
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return // cancelled sleep returns immediately
            }
            await self?.idleExpired(gen: gen)
        }
    }

    private func idleExpired(gen: UInt64) async {
        guard gen == generation, owner == nil, !transitioning, let lease = cached else { return }
        transitioning = true
        generation &+= 1
        cached = nil
        await lease.client.shutdown()
        finishTransition()
    }

    private func finishTransition() {
        transitioning = false
        let resumed = waiters
        waiters = []
        for w in resumed { w.resume() }
    }
}
