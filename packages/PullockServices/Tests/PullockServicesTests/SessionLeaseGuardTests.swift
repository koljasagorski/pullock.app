import Foundation
import PullockCore
import PullockIPC
@testable import PullockServices
import Testing

@MainActor
private final class LeaseFixture {
    let host: ProtectionAuthority
    let owner: OwnerSessionPolicy
    var now: UInt64 = 100
    var calls: [ActionID] = []
    lazy var executor = LockActionExecutor { id in self.calls.append(id); return .unknown }
    lazy var lease = SessionLeaseGuard(executor: executor, clock: { self.now })

    init(profile: ExecutionProfile = .live) throws {
        host = try ProtectionAuthority(capabilities: .init(profile: profile, lock: .qualified))
        owner = try OwnerSessionPolicy(uid: 501, auditSession: 42, active: true)
        try host.bindOwner(owner, now: 100)
        let device = WireDevice(instance: 12, vendorID: 0x1234, productID: 0x5678, name: "Device")
        var state = host.snapshot(now: 100)
        try host.inventory([device], epoch: state.epoch, now: 100)
        let connection = try ConnectionIdentity(bootID: host.bootID, watcher: state.epoch.watcher, power: state.epoch.power, instance: 12)
        let policy = try ProtectionPolicy(revision: 1, enrollment: Enrollment(id: UUID(), vendorID: device.vendorID,
            productID: device.productID, connection: connection))
        _ = try host.command(.configure(policy: policy, expectedRevision: nil), role: .app, owner: owner, now: 100)
        for component in HealthComponent.allCases { host.processed(component, now: 100) }
        _ = try host.command(.arm(expectedRevision: 1), role: .app, owner: owner, now: 100)
        state = host.snapshot(now: 100)
        try host.inventory([device], epoch: state.epoch, now: 100)
    }
}

@Test @MainActor func permissionGateRejectsArmedAndTriggeredSnapshots() throws {
    let f = try LeaseFixture(), gate = SessionPermissionGate(clock: { f.now })
    var calls = 0
    let armed = f.host.snapshot(now: f.now)
    #expect(!gate.handle(id: UUID(), requestedAt: 100, expiresAt: 5_100,
        state: armed, ticket: gate.ticket) { calls += 1 })
    f.host.removed(instance: 12, epoch: armed.epoch, now: f.now)
    let triggered = f.host.snapshot(now: f.now)
    #expect(triggered.trigger != nil)
    #expect(!gate.handle(id: UUID(), requestedAt: 100, expiresAt: 5_100,
        state: triggered, ticket: gate.ticket) { calls += 1 })
    #expect(calls == 0)
}

@Test @MainActor func stalledDaemonLeaseRequestsOneFallbackAndSharesDeduplication() throws {
    let f = try LeaseFixture()
    let state = f.host.snapshot(now: f.now)
    #expect(state.isProtected(at: f.now))
    try f.lease.observe(state)
    f.now = state.validUntil - 1
    #expect(f.lease.tick() == nil)
    f.now += 1
    let result = try #require(f.lease.tick())
    #expect(result.outcome == .unknown && f.calls.count == 1)
    #expect(f.lease.tick() == nil)
    _ = try f.executor.execute(result.id) // A later daemon fallback is the same action.
    #expect(f.calls.count == 1)
}

@Test @MainActor func freshDisarmCancelsIndependentFallback() throws {
    let f = try LeaseFixture()
    let state = f.host.snapshot(now: f.now)
    try f.lease.observe(state)
    _ = try f.host.command(.disarm(expectedArming: state.epoch.arming), role: .app, owner: f.owner, now: 101)
    f.now = 101; try f.lease.observe(f.host.snapshot(now: f.now))
    f.now = 5_000
    #expect(f.lease.tick() == nil && f.calls.isEmpty)
}

@Test @MainActor func sleepAndInactiveSessionCancelIndependentFallback() throws {
    for boundary in [0, 1, 2] {
        let f = try LeaseFixture()
        try f.lease.observe(f.host.snapshot(now: f.now))
        f.now = 101
        if boundary == 0 { f.lease.suspend() }
        else {
            if boundary == 1 { try f.host.lifecycle(.willSleep, now: f.now) }
            else { f.host.ownerBecameInactive(now: f.now) }
            try f.lease.observe(f.host.snapshot(now: f.now))
        }
        f.now = 5_000
        #expect(f.lease.tick() == nil && f.calls.isEmpty)
    }
}

@Test @MainActor func staleAndSimulatedSnapshotsCannotStartLiveFallback() throws {
    for simulated in [false, true] {
        let f = try LeaseFixture(profile: simulated ? .simulation : .live)
        let state = f.host.snapshot(now: f.now)
        if !simulated { f.now = 5_000 }
        try f.lease.observe(state)
        f.now = 6_000
        #expect(f.lease.tick() == nil && f.calls.isEmpty)
    }
}

@Test @MainActor func queuedPreSleepSnapshotCannotRestoreSuspendedLease() throws {
    let f = try LeaseFixture()
    try f.lease.observe(f.host.snapshot(now: f.now))
    f.now = 101
    let queued = f.host.snapshot(now: f.now) // Newer revision, same armed epoch.
    f.lease.suspend()
    f.now = 102
    try f.lease.observe(queued)
    f.now = 5_000
    #expect(f.lease.tick() == nil && f.calls.isEmpty)
}

@Test @MainActor func suspendBeforeFirstReplyRejectsPreBoundarySnapshot() throws {
    let f = try LeaseFixture()
    let queued = f.host.snapshot(now: f.now)
    f.now = 101
    f.lease.suspend()
    try f.lease.observe(queued)
    f.now = 5_000
    #expect(f.lease.tick() == nil && f.calls.isEmpty)
}

@Test @MainActor func postBoundaryTimestampCannotRenewTheSuspendedArming() throws {
    for observedBeforeSleep in [false, true] {
        let f = try LeaseFixture()
        if observedBeforeSleep { try f.lease.observe(f.host.snapshot(now: f.now)) }
        f.lease.suspend()
        f.now = 101
        try f.lease.observe(f.host.snapshot(now: f.now))
        f.now = 102
        try f.lease.observe(f.host.snapshot(now: f.now))
        f.now = 5_000
        #expect(f.lease.tick() == nil && f.calls.isEmpty)
    }
}

@Test @MainActor func explicitNewArmingRestoresFallbackAfterLocalBoundary() throws {
    let f = try LeaseFixture()
    let previous = f.host.snapshot(now: f.now)
    try f.lease.observe(previous)
    f.lease.suspend()
    f.now = 101
    _ = try f.host.command(.disarm(expectedArming: previous.epoch.arming), role: .app, owner: f.owner, now: f.now)
    _ = try f.host.command(.arm(expectedRevision: 1), role: .app, owner: f.owner, now: f.now)
    let rearming = f.host.snapshot(now: f.now)
    try f.host.inventory([WireDevice(instance: 12, vendorID: 0x1234, productID: 0x5678, name: "Device")],
        epoch: rearming.epoch, now: f.now)
    let current = f.host.snapshot(now: f.now)
    #expect(current.isProtected(at: f.now) && current.epoch.arming != previous.epoch.arming)
    try f.lease.observe(current)
    f.now = current.validUntil
    #expect(f.lease.tick()?.outcome == .unknown && f.calls.count == 1)
}
