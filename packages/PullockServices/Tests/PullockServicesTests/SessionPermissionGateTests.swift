import Foundation
import PullockCore
import PullockIPC
import PullockServices
import Testing

@MainActor private final class PermissionFixture {
    var now: UInt64 = 100
    var calls = 0
    lazy var gate = SessionPermissionGate(clock: { self.now })
    let host: ProtectionAuthority
    init(profile: ExecutionProfile = .live) throws {
        host = try ProtectionAuthority(capabilities: .init(profile: profile))
        try host.bindOwner(OwnerSessionPolicy(uid: 501, auditSession: 42, active: true), now: now)
    }
    func handle(id: UUID = UUID(), ticket: UUID? = nil, requestedAt: UInt64 = 100,
                expiresAt: UInt64 = 5_100, state: StateSnapshot? = nil) -> Bool {
        gate.handle(id: id, requestedAt: requestedAt, expiresAt: expiresAt,
            state: state ?? host.snapshot(now: now), ticket: ticket ?? gate.ticket) { self.calls += 1 }
    }
}

@Test @MainActor func permissionSetupConsumesRequestBeforeCallingOSAndDoesNotRetry() throws {
    let f = try PermissionFixture(), id = UUID(), ticket = f.gate.ticket
    #expect(f.handle(id: id, ticket: ticket))
    #expect(!f.handle(id: UUID(), ticket: ticket)) // Ticket is single use too.
    #expect(!f.handle(id: id))
    #expect(f.calls == 1)
    let failing = UUID()
    #expect(throws: AuthorityError.unavailable) {
        try f.gate.handle(id: failing, requestedAt: 100, expiresAt: 5_100,
            state: f.host.snapshot(now: f.now), ticket: f.gate.ticket) { throw AuthorityError.unavailable }
    }
    #expect(!f.handle(id: failing))
    #expect(f.calls == 1)
}

@Test @MainActor func permissionReplyQueuedAcrossLocalSleepOrSessionBoundaryIsDiscarded() throws {
    let f = try PermissionFixture(), ticket = f.gate.ticket
    f.now = 101; f.gate.suspend(); f.now = 102
    #expect(!f.handle(ticket: ticket, requestedAt: 100))
    // Even a new poll and newly dated snapshot cannot revive a pre-sleep request.
    #expect(!f.handle(requestedAt: 100))
    #expect(f.calls == 0)
    #expect(f.handle(requestedAt: 102, expiresAt: 5_102))
    #expect(f.calls == 1)
}

@Test @MainActor func permissionSetupRejectsStaleFutureAndOverlongRequests() throws {
    let f = try PermissionFixture(), state = f.host.snapshot(now: f.now)
    #expect(!f.handle(requestedAt: 101))
    #expect(!f.handle(expiresAt: 5_101))
    #expect(!f.handle(expiresAt: 100))
    f.now = state.validUntil
    #expect(!f.handle(state: state))
    f.now = 5_100
    #expect(!f.handle())
    #expect(f.calls == 0)
}

@Test @MainActor func permissionSetupRequiresAwakeActiveLiveSession() throws {
    for boundary in 0..<3 {
        let f = try PermissionFixture(profile: boundary == 2 ? .simulation : .live)
        if boundary == 0 { try f.host.lifecycle(.willSleep, now: f.now) }
        if boundary == 1 { f.host.ownerBecameInactive(now: f.now) }
        #expect(!f.handle())
        #expect(f.calls == 0)
    }
}
