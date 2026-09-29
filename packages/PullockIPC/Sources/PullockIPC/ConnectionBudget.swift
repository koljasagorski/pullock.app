import Foundation

public enum ConnectionBudgetError: String, Error, Sendable {
    case closed, clockRollback, tooLarge, tooManyPending, rateExceeded, timeout, unknownRequest, exhausted
}

/// Per-connection admission before decoding. A trusted monotonic millisecond
/// clock and a serialized owner are required. These are resource limits, not
/// authentication or a substitute for global connection limits in the listener.
public struct ConnectionBudget: Sendable {
    public static let maximumPending = 8
    public static let burst = 16
    public static let refillMilliseconds: UInt64 = 100
    public static let deadlineMilliseconds: UInt64 = 2_000
    public private(set) var closed = false
    public var pendingCount: Int { deadlines.count }
    private var lastTime: UInt64?
    private var lastRefill: UInt64?
    private var tokens = Self.burst
    private var nextID: UInt64 = 1
    private var deadlines: [UInt64: UInt64] = [:]

    public init() {}

    public mutating func begin(byteCount: Int, now: UInt64) throws -> UInt64 {
        try checkTime(now)
        guard byteCount > 0, byteCount <= WireCodec.maximumBytes else { throw fail(.tooLarge) }
        guard deadlines.count < Self.maximumPending else { throw fail(.tooManyPending) }
        if let lastRefill {
            let replenished = (now - lastRefill) / Self.refillMilliseconds
            tokens = min(Self.burst, tokens + Int(min(replenished, UInt64(Self.burst))))
            self.lastRefill = now - ((now - lastRefill) % Self.refillMilliseconds)
        } else { lastRefill = now }
        guard tokens > 0 else { throw fail(.rateExceeded) }
        guard nextID < UInt64.max, now <= UInt64.max - Self.deadlineMilliseconds else { throw fail(.exhausted) }
        let id = nextID
        nextID += 1; tokens -= 1
        deadlines[id] = now + Self.deadlineMilliseconds
        return id
    }

    public mutating func finish(_ id: UInt64, now: UInt64) throws {
        try checkTime(now)
        guard deadlines.removeValue(forKey: id) != nil else { throw fail(.unknownRequest) }
    }

    /// The transport host must also schedule this while no new input arrives;
    /// checking only on the next message would not enforce an idle deadline.
    public mutating func checkTime(_ now: UInt64) throws {
        guard !closed else { throw ConnectionBudgetError.closed }
        if let lastTime, now < lastTime { throw fail(.clockRollback) }
        lastTime = now
        if deadlines.values.contains(where: { now >= $0 }) { throw fail(.timeout) }
    }

    public mutating func invalidate() {
        closed = true
        deadlines.removeAll()
    }

    private mutating func fail(_ error: ConnectionBudgetError) -> ConnectionBudgetError {
        invalidate()
        return error
    }
}
