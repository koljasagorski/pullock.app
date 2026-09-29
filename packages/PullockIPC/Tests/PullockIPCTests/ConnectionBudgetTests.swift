import PullockIPC
import Testing

@Test func payloadBoundsCloseBeforeDecoding() {
    for count in [-1, 0, WireCodec.maximumBytes + 1, Int.max] {
        var budget = ConnectionBudget()
        #expect(throws: ConnectionBudgetError.tooLarge) { try budget.begin(byteCount: count, now: 0) }
        #expect(budget.closed)
        #expect(throws: ConnectionBudgetError.closed) { try budget.begin(byteCount: 1, now: 1) }
    }
}

@Test func pendingRequestsAreBoundedAndReleasedOnFailure() throws {
    var budget = ConnectionBudget()
    for _ in 0..<ConnectionBudget.maximumPending { _ = try budget.begin(byteCount: 1, now: 0) }
    #expect(budget.pendingCount == 8)
    #expect(throws: ConnectionBudgetError.tooManyPending) { try budget.begin(byteCount: 1, now: 0) }
    #expect(budget.closed && budget.pendingCount == 0)
}

@Test func rateLimitCannotBeBypassedWithImmediateReplies() throws {
    var budget = ConnectionBudget()
    for _ in 0..<ConnectionBudget.burst {
        let id = try budget.begin(byteCount: 1, now: 0)
        try budget.finish(id, now: 0)
    }
    #expect(throws: ConnectionBudgetError.rateExceeded) { try budget.begin(byteCount: 1, now: 99) }
}

@Test func tokenRefillUsesElapsedMonotonicTime() throws {
    var budget = ConnectionBudget()
    for _ in 0..<ConnectionBudget.burst {
        try budget.finish(budget.begin(byteCount: 1, now: 0), now: 0)
    }
    let id = try budget.begin(byteCount: WireCodec.maximumBytes, now: 100)
    try budget.finish(id, now: 100)
    #expect(throws: ConnectionBudgetError.rateExceeded) { try budget.begin(byteCount: 1, now: 100) }
}

@Test func idleTimeoutRevokesAllOutstandingRequests() throws {
    var budget = ConnectionBudget()
    _ = try budget.begin(byteCount: 1, now: 50)
    try budget.checkTime(2_049)
    #expect(throws: ConnectionBudgetError.timeout) { try budget.checkTime(2_050) }
    #expect(budget.closed && budget.pendingCount == 0)
}

@Test func lateOrDuplicateReplyCannotRestoreConnection() throws {
    var budget = ConnectionBudget()
    let id = try budget.begin(byteCount: 1, now: 0)
    try budget.finish(id, now: 1)
    #expect(throws: ConnectionBudgetError.unknownRequest) { try budget.finish(id, now: 2) }
    var other = ConnectionBudget()
    let late = try other.begin(byteCount: 1, now: 0)
    #expect(throws: ConnectionBudgetError.timeout) { try other.finish(late, now: 2_000) }
}

@Test func rollbackOverflowAndInvalidationFailClosed() throws {
    var budget = ConnectionBudget()
    _ = try budget.begin(byteCount: 1, now: 100)
    #expect(throws: ConnectionBudgetError.clockRollback) { try budget.checkTime(99) }
    var overflow = ConnectionBudget()
    #expect(throws: ConnectionBudgetError.exhausted) { try overflow.begin(byteCount: 1, now: UInt64.max - 1) }
    var revoked = ConnectionBudget()
    revoked.invalidate()
    #expect(throws: ConnectionBudgetError.closed) { try revoked.begin(byteCount: 1, now: 0) }
}
