import Foundation
import PullockCore
import PullockIPC
import PullockServices
import Synchronization

public enum DaemonRuntimeError: String, Error, Sendable {
    case stopped, expiredCommand, observationUnavailable, powerRegistration, sessionRegistration
}

/// All inventory reads, lifecycle events and commands share the main actor.
/// The epoch is captured BEFORE enumeration; an old inventory can never become
/// fresh merely because a command advanced the arming epoch on another queue.
@MainActor
final class DaemonCoordinator {
    nonisolated let bootID: UUID
    nonisolated let cache: SnapshotCache
    private let authority: ProtectionAuthority
    private let clock: @MainActor () -> UInt64
    private let readInventory: @MainActor () throws -> [WireDevice]
    private let validateOwner: @MainActor (UInt32, Int32) throws -> OwnerSessionPolicy
    private let actionSink: @MainActor (ActionRequest) -> Void
    private let lockRouteAvailable: @MainActor (OwnerSessionPolicy) -> Bool
    private var owner: OwnerSessionPolicy?
    private var ownerActive = false
    private var running = true
    private var watcherReady = false
    private var pendingInventory: ObservationEpoch?
    private var draining = false

    init(capabilities: RuntimeCapabilities = .init(),
         clock: @escaping @MainActor () -> UInt64 = { MonotonicTime.milliseconds },
         readInventory: @escaping @MainActor () throws -> [WireDevice],
         validateOwner: @escaping @MainActor (UInt32, Int32) throws -> OwnerSessionPolicy,
         actionSink: @escaping @MainActor (ActionRequest) -> Void = { _ in },
         lockRouteAvailable: @escaping @MainActor (OwnerSessionPolicy) -> Bool = { _ in false }) throws {
        authority = try ProtectionAuthority(capabilities: capabilities)
        bootID = authority.bootID
        self.clock = clock; self.readInventory = readInventory
        self.validateOwner = validateOwner; self.actionSink = actionSink
        self.lockRouteAvailable = lockRouteAvailable
        cache = SnapshotCache(authority.snapshot(now: clock()))
    }

    /// Credentials were authenticated at the XPC boundary. Revalidate them
    /// after the queue handoff, before binding or changing authority state.
    func command(role: ProcessRole, uid: UInt32, session: Int32, receivedAt: UInt64,
                 payload: WirePayload) throws -> WirePayload {
        guard running else { throw DaemonRuntimeError.stopped }
        defer { drainEffects(); publish() }
        try checkDeadline(receivedAt)
        let current: OwnerSessionPolicy
        do {
            current = try validateOwner(uid, session)
            try current.validate(effectiveUID: uid, auditSession: session)
        }
        catch { recheckOwner(); throw error }
        try authority.bindOwner(current, now: clock())
        owner = current; ownerActive = true
        drainEffects()
        // Reconciliation can be slower than the queue handoff. Never mutate
        // policy/arming after the caller's admission deadline has elapsed.
        try checkDeadline(receivedAt)
        let effective: WirePayload
        if case let .sessionReadiness(generation, progress, available) = payload {
            effective = .sessionReadiness(generation: generation, progress: progress,
                lockAvailable: available && lockRouteAvailable(current))
        } else { effective = payload }
        refreshLocalReadiness()
        let result = try authority.command(effective, role: role, owner: current, now: clock())
        switch effective {
        case .disarm, .resetTrigger: pendingInventory = authority.snapshot(now: clock()).epoch
        default: break
        }
        drainEffects()
        // A command's response includes the result of its fresh reconciliation.
        if case .snapshot = result { return .snapshot(state: authority.snapshot(now: clock())) }
        return result
    }

    func watcherStarted() {
        guard running else { return }
        watcherReady = true
        pendingInventory = authority.snapshot(now: clock()).epoch
        drainEffects(); publish()
    }

    func inventoryChanged() {
        guard running, watcherReady else { return }
        pendingInventory = authority.snapshot(now: clock()).epoch
        drainEffects(); publish()
    }

    func removed(_ instance: UInt64) {
        guard running, watcherReady else { return }
        recheckOwner()
        authority.removed(instance: instance, epoch: authority.snapshot(now: clock()).epoch, now: clock())
        drainEffects(); publish()
    }

    func observationFailed() {
        guard running else { return }
        watcherReady = false; pendingInventory = nil
        try? authority.lifecycle(.watcherRestarted, now: clock())
        authority.processed(.watcher, condition: .failed, now: clock())
        drainEffects(); publish()
    }

    func lifecycle(_ event: ProtectionEvent) {
        guard running else { return }
        if case .watcherRestarted = event { observationFailed(); return }
        do { try authority.lifecycle(event, now: clock()) }
        catch { observationFailed(); return }
        drainEffects(); publish()
    }

    func pulse() {
        guard running else { return }
        recheckOwner()
        // Progress proves this event loop was serviced, not USB future health.
        authority.processed(.daemon, now: clock())
        if watcherReady { authority.processed(.watcher, now: clock()) }
        refreshLocalReadiness()
        drainEffects(); publish()
    }

    func recheckOwner() {
        guard running, let owner, ownerActive else { return }
        do {
            let current = try validateOwner(owner.uid, owner.auditSession)
            try current.validate(effectiveUID: owner.uid, auditSession: owner.auditSession)
        } catch {
            ownerActive = false
            authority.ownerBecameInactive(now: clock())
            pendingInventory = nil
            drainEffects(); publish()
        }
    }

    func stop() {
        guard running else { return }
        observationFailed()
        authority.ownerBecameInactive(now: clock())
        running = false; pendingInventory = nil
        drainEffects(); publish()
    }

    var currentOwner: OwnerSessionPolicy? { ownerActive ? owner : nil }

    /// Results originate from the authenticated route owned by this host.
    /// Transport loss is uncertain: never turn it into confirmed lock success.
    func actionCompleted(_ result: ActionResult, for owner: OwnerSessionPolicy) {
        guard running else { return }
        recheckOwner()
        guard ownerActive, self.owner?.uid == owner.uid,
              self.owner?.auditSession == owner.auditSession else { return }
        _ = try? authority.command(.lockResult(result: result), role: .sessionAgent, owner: owner, now: clock())
        drainEffects(); publish()
    }

    private func refreshLocalReadiness() {
        let state = authority.snapshot(now: clock())
        authority.processed(.policy, condition: state.policyRevision == nil ? .unavailable : .healthy, now: clock())
        authority.processed(.identity, condition: state.matchingDeviceCount == 1 ? .healthy : .unavailable, now: clock())
        if let owner, !lockRouteAvailable(owner) {
            authority.processed(.lockPath, condition: .unavailable, now: clock())
        }
    }

    private func checkDeadline(_ receivedAt: UInt64) throws {
        let now = clock()
        guard now >= receivedAt, now - receivedAt < 1_000 else { throw DaemonRuntimeError.expiredCommand }
    }

    private func drainEffects() {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        // Each reducer transition yields a bounded batch. Cap reentrant work
        // as well; unexpected replenishment becomes a failed observation path.
        for _ in 0..<8 {
            let effects = authority.takeEffects()
            for effect in effects {
                switch effect {
                case let .requestInventory(epoch): pendingInventory = epoch
                case let .action(request): actionSink(request)
                }
            }
            guard running, watcherReady, let epoch = pendingInventory,
                  authority.snapshot(now: clock()).power == .awake else { return }
            pendingInventory = nil
            do {
                let devices = try readInventory()
                try authority.inventory(devices, epoch: epoch, now: clock())
                refreshLocalReadiness()
            } catch {
                watcherReady = false
                try? authority.lifecycle(.watcherRestarted, now: clock())
                authority.processed(.watcher, condition: .failed, now: clock())
            }
        }
        watcherReady = false; pendingInventory = nil
        authority.processed(.watcher, condition: .failed, now: clock())
        for effect in authority.takeEffects() {
            if case let .action(request) = effect { actionSink(request) }
        }
    }

    private func publish() { cache.store(authority.snapshot(now: clock())) }
}

/// XPC can read a frozen copy without hopping onto the monitored event loop.
/// If the loop stalls, this snapshot expires; XPC traffic cannot renew it.
final class SnapshotCache: Sendable {
    private let value: Mutex<StateSnapshot>
    init(_ value: StateSnapshot) { self.value = Mutex(value) }
    func load() -> StateSnapshot { value.withLock { $0 } }
    func store(_ snapshot: StateSnapshot) { value.withLock { $0 = snapshot } }
}
