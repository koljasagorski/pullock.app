import Foundation
import PullockCore

/// Independent session-loop fallback for a previously authenticated ARMED
/// lease. Disconnects do not renew it. Fresh disarm, power/session boundaries
/// and new arming epochs clear it; a stale or simulated view cannot start it.
@MainActor
public final class SessionLeaseGuard {
    private let executor: LockActionExecutor
    private let clock: @MainActor () -> UInt64
    private var boot: UUID?
    private var revision: UInt64 = 0
    private var armed: StateSnapshot?
    private var observedArming: TriggerID?
    private var suspendedAt: UInt64?
    private var suspendedArming: TriggerID?

    public init(executor: LockActionExecutor,
                clock: @escaping @MainActor () -> UInt64 = { MonotonicTime.milliseconds }) {
        self.executor = executor; self.clock = clock
    }

    /// Only snapshots received through the authenticated NativeHealthClient.
    public func observe(_ state: StateSnapshot) throws {
        let now = clock()
        guard state.generatedAt <= now, now < state.validUntil else { return }
        let arming = TriggerID(boot: state.bootID, arming: state.epoch.arming)
        if let suspendedAt {
            guard state.generatedAt > suspendedAt else { return }
            // A daemon can process our notification later than this process.
            // A newer timestamp alone must never revive the old armed lease.
            // If no view preceded suspension, quarantine the first epoch too.
            if suspendedArming == nil { suspendedArming = arming }
            guard arming != suspendedArming else { return }
        }
        if boot != state.bootID {
            try executor.bind(boot: state.bootID)
            boot = state.bootID; revision = 0; armed = nil
        }
        guard state.revision > revision else { return }
        revision = state.revision
        observedArming = arming
        suspendedAt = nil; suspendedArming = nil
        if !state.armIntent || state.power != .awake || state.session != .activeOwner
            || state.trigger != nil || armed.map({ $0.epoch != state.epoch }) == true {
            armed = nil
        }
        if state.isProtected(at: now) { armed = state }
    }

    /// Native sleep/session notifications also cancel the remembered lease.
    /// Recovery requires a fresh view in a different boot/arming epoch.
    /// Queued replies and same-epoch renewals cannot undo the local boundary.
    public func suspend() {
        armed = nil
        suspendedAt = clock()
        suspendedArming = observedArming
    }

    @discardableResult public func tick() -> ActionResult? {
        guard let state = armed, clock() >= state.validUntil else { return nil }
        armed = nil // Latch before the synchronous operation, even if it throws.
        let id = ActionID(trigger: TriggerID(boot: state.bootID, arming: state.epoch.arming),
            kind: .lock, cause: .healthFailure)
        return try? executor.execute(id)
    }
}
