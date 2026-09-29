import Foundation
import PullockCore

public enum LockExecutorError: Error { case wrongBoot, staleArming, exhausted, invalidResult }

/// Session-agent lifetime, not connection lifetime. Reconnects do not replay
/// completed actions. The injected operation is synchronous on the main actor.
@MainActor
public final class LockActionExecutor {
    private var boot: UUID?
    private var retiredBoots: Set<UUID> = []
    private var arming: UInt64 = 0
    private var results: [ActionID: ActionResult] = [:]
    private let operation: @MainActor (ActionID) throws -> ActionOutcome

    public init(operation: @escaping @MainActor (ActionID) throws -> ActionOutcome) { self.operation = operation }

    public func bind(boot: UUID) throws {
        guard self.boot != boot else { return }
        guard !retiredBoots.contains(boot) else { throw LockExecutorError.wrongBoot }
        guard retiredBoots.count < 16 else { throw LockExecutorError.exhausted }
        if let previous = self.boot { retiredBoots.insert(previous) }
        self.boot = boot; arming = 0; results.removeAll()
    }

    public func execute(_ id: ActionID) throws -> ActionResult {
        guard id.trigger.boot == boot, id.kind == .lock else { throw LockExecutorError.wrongBoot }
        guard id.trigger.arming > 0, id.trigger.arming >= arming else { throw LockExecutorError.staleArming }
        if let completed = results[id] { return completed }
        if id.trigger.arming > arming { arming = id.trigger.arming; results.removeAll() }
        guard results.count < 8 else { throw LockExecutorError.exhausted }
        // Latch failure before invoking any code. A thrown operation cannot be
        // replayed by retrying the same ID after reconnect.
        results[id] = ActionResult(id: id, outcome: .failed)
        let outcome: ActionOutcome
        do { outcome = try operation(id) }
        catch { return results[id]! }
        guard outcome == .unknown || outcome == .failed else { throw LockExecutorError.invalidResult }
        let result = ActionResult(id: id, outcome: outcome)
        results[id] = result
        return result
    }
}
