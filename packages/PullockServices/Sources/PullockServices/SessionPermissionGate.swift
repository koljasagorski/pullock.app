import Foundation
import PullockCore

/// Local lifecycle fencing for explicit permission setup. Capturing a ticket
/// before awaiting XPC prevents a reply queued across sleep or session loss
/// from opening a permission prompt after the boundary. No lock capability.
@MainActor
public final class SessionPermissionGate {
    public private(set) var ticket = UUID()
    private var lastRequest: UUID?
    private var suspendedAt: UInt64?
    private let clock: @MainActor () -> UInt64

    public init(clock: @escaping @MainActor () -> UInt64 = { MonotonicTime.milliseconds }) {
        self.clock = clock
    }

    public func suspend() { ticket = UUID(); suspendedAt = clock() }

    @discardableResult public func handle(id: UUID, requestedAt: UInt64, expiresAt: UInt64, state: StateSnapshot,
        ticket: UUID, request: @MainActor () throws -> Void) rethrows -> Bool {
        let now = clock()
        guard ticket == self.ticket, id != lastRequest,
              state.generatedAt <= now, now < state.validUntil, now < expiresAt,
              requestedAt <= state.generatedAt, expiresAt > requestedAt, expiresAt - requestedAt <= 5_000,
              suspendedAt.map({ requestedAt > $0 }) ?? true, state.profile == .live,
              !state.armIntent, state.trigger == nil, state.power == .awake,
              state.session == .activeOwner else { return false }
        lastRequest = id // Consume before even a failing OS request.
        self.ticket = UUID()
        try request()
        return true
    }
}
