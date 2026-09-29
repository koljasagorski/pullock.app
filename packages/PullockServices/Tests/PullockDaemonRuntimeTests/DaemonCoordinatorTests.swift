import Foundation
import PullockCore
import PullockIPC
import PullockServices
@testable import PullockDaemonRuntime
import Testing

@MainActor
private final class Fixture {
    var now: UInt64 = 100
    var devices = [WireDevice(instance: 12, vendorID: 0x1234, productID: 0x4321, name: "Stick")]
    var active = true
    var reads = 0
    var readDelay: UInt64 = 0
    var readFails = false
    var actions: [ActionRequest] = []
    var routeAvailable = false
    var capabilities = RuntimeCapabilities()
    lazy var host = try! DaemonCoordinator(capabilities: capabilities, clock: { self.now }, readInventory: {
        self.reads += 1; self.now += self.readDelay
        if self.readFails { throw DaemonRuntimeError.observationUnavailable }
        return self.devices
    }, validateOwner: { uid, session in
        guard uid == 501, session == 42 else { throw PeerPolicyError.wrongSession }
        return try OwnerSessionPolicy(uid: uid, auditSession: session, active: self.active)
    }, actionSink: { self.actions.append($0) }, lockRouteAvailable: { _ in self.routeAvailable })

    func request(_ payload: WirePayload, receivedAt: UInt64? = nil) throws -> WirePayload {
        try host.command(role: .app, uid: 501, session: 42, receivedAt: receivedAt ?? now, payload: payload)
    }

    func select() throws -> ProtectionPolicy {
        let result = try request(.getDevices)
        guard case let .devices(inventory, state) = result else { throw AuthorityError.unavailable }
        let device = try #require(inventory.first)
        let connection = try ConnectionIdentity(bootID: state.bootID, watcher: state.epoch.watcher,
            power: state.epoch.power, instance: device.instance)
        let policy = try ProtectionPolicy(revision: (state.policyRevision ?? 0) + 1,
            enrollment: try Enrollment(id: UUID(), vendorID: device.vendorID, productID: device.productID, connection: connection))
        _ = try request(.configure(policy: policy, expectedRevision: state.policyRevision))
        return policy
    }

    func readiness(_ available: Bool) throws {
        host.pulse()
        _ = try host.command(role: .sessionAgent, uid: 501, session: 42, receivedAt: now,
            payload: .sessionReadiness(generation: host.cache.load().healthGeneration,
                progress: now, lockAvailable: available))
    }
}

@Test @MainActor func selectedDeviceAloneTriggersTheIntegratedHost() throws {
    let fixture = Fixture()
    fixture.capabilities = .init(profile: .simulation, lock: .mockOnly)
    fixture.routeAvailable = true
    fixture.devices.append(WireDevice(instance: 99, vendorID: 0x2222, productID: 0x1111, name: "Mouse"))
    fixture.host.watcherStarted(); fixture.host.pulse()
    let policy = try fixture.select()
    try fixture.readiness(true)
    _ = try fixture.request(.arm(expectedRevision: policy.revision))
    #expect(fixture.host.cache.load().status == .armed)
    fixture.host.removed(99)
    #expect(fixture.actions.isEmpty && fixture.host.cache.load().status == .armed)
    fixture.host.removed(12); fixture.host.removed(12)
    #expect(fixture.actions.count == 1)
    let action = try #require(fixture.actions.first)
    #expect(action.id.cause == .removal && action.id.kind == .lock)
    fixture.host.actionCompleted(ActionResult(id: action.id, outcome: .unknown),
        for: try OwnerSessionPolicy(uid: 501, auditSession: 42, active: true))
    #expect(fixture.host.cache.load().lockOutcome == .unknown)
}

@Test @MainActor func readinessNeedsBothAgentPreflightAndUniqueAuthenticatedRoute() throws {
    for route in [false, true] {
        let fixture = Fixture()
        fixture.capabilities = .init(profile: .simulation, lock: .mockOnly)
        fixture.routeAvailable = route
        fixture.host.watcherStarted(); fixture.host.pulse()
        let policy = try fixture.select()
        try fixture.readiness(!route)
        _ = try fixture.request(.arm(expectedRevision: policy.revision))
        #expect(fixture.host.cache.load().status != .armed)
        fixture.host.removed(12)
        #expect(fixture.actions.isEmpty)
    }
}

@Test @MainActor func routeLossInvalidatesArmedStateAndRequiresExplicitRecovery() throws {
    let fixture = Fixture()
    fixture.capabilities = .init(profile: .simulation, lock: .mockOnly)
    fixture.routeAvailable = true
    fixture.host.watcherStarted(); fixture.host.pulse()
    let policy = try fixture.select(); try fixture.readiness(true)
    _ = try fixture.request(.arm(expectedRevision: policy.revision))
    #expect(fixture.host.cache.load().status == .armed)
    fixture.routeAvailable = false; fixture.host.pulse()
    #expect(fixture.host.cache.load().status == .error)
    #expect(fixture.actions.count == 1 && fixture.actions[0].id.cause == .healthFailure)
    fixture.routeAvailable = true; fixture.now += 1; try fixture.readiness(true)
    #expect(fixture.host.cache.load().status == .error)
}

@Test @MainActor func disarmAndResetRefreshInventoryBeforeChoosingAgain() throws {
    let fixture = Fixture()
    fixture.capabilities = .init(profile: .simulation, lock: .mockOnly)
    fixture.routeAvailable = true
    fixture.host.watcherStarted(); fixture.host.pulse()
    let policy = try fixture.select(); try fixture.readiness(true)
    _ = try fixture.request(.arm(expectedRevision: policy.revision))
    _ = try fixture.request(.disarm(expectedArming: fixture.host.cache.load().epoch.arming))
    let second = try fixture.select()
    _ = try fixture.request(.arm(expectedRevision: second.revision))
    fixture.devices = []; fixture.host.removed(12)
    let action = try #require(fixture.actions.last)
    fixture.host.actionCompleted(ActionResult(id: action.id, outcome: .unknown),
        for: try OwnerSessionPolicy(uid: 501, auditSession: 42, active: true))
    fixture.devices = [WireDevice(instance: 13, vendorID: 0x2222, productID: 0x1111, name: "Different device")]
    _ = try fixture.request(.resetTrigger(id: action.id.trigger))
    #expect(try fixture.select().enrollment.connection?.instance == 13)
}

@Test @MainActor func daemonOwnsFreshInventoryAcrossConfigureAndArm() throws {
    let fixture = Fixture()
    fixture.host.watcherStarted()
    #expect(fixture.reads == 1)
    let policy = try fixture.select()
    #expect(fixture.reads == 2) // Binding the authenticated owner requires a new read.
    let response = try fixture.request(.arm(expectedRevision: policy.revision))
    #expect(fixture.reads == 3) // Arming also enumerates under the new epoch.
    guard case let .snapshot(state) = response else { Issue.record("Expected snapshot"); return }
    #expect(state.epoch.arming == fixture.host.cache.load().epoch.arming)
    #expect(state.status != .armed && !state.isProtected(at: fixture.now))
    #expect(fixture.actions.isEmpty)
}

@Test @MainActor func daemonRemovalExpiresSelectionEvenWithWindowDisconnected() throws {
    let fixture = Fixture(); fixture.host.watcherStarted()
    let policy = try fixture.select()
    // No client calls during the removal/replug interval.
    fixture.now += 10; fixture.devices = []
    fixture.host.removed(12)
    fixture.devices = [WireDevice(instance: 13, vendorID: 0x1234, productID: 0x4321, name: "Stick")]
    fixture.host.inventoryChanged()
    #expect(fixture.host.cache.load().issues.contains(.selectionExpired))
    #expect(throws: AuthorityError.rejected) { try fixture.request(.arm(expectedRevision: policy.revision)) }
    #expect(throws: AuthorityError.rejected) {
        try fixture.request(.configure(policy: ProtectionPolicy(revision: 2, enrollment: policy.enrollment), expectedRevision: 1))
    }
    let new = try fixture.select()
    #expect(new.enrollment.connection?.instance == 13 && new.revision == 2)
}

@Test @MainActor func daemonDefersReadsDuringSleepAndExpiresChoiceAcrossWake() throws {
    let fixture = Fixture(); fixture.host.watcherStarted()
    let policy = try fixture.select(), before = fixture.reads
    fixture.host.lifecycle(.willSleep)
    fixture.host.inventoryChanged()
    #expect(fixture.reads == before)
    #expect(throws: AuthorityError.unavailable) { try fixture.request(.getDevices) }
    fixture.host.lifecycle(.willWake); fixture.host.lifecycle(.didWake)
    #expect(fixture.reads == before + 1)
    #expect(fixture.host.cache.load().issues.contains(.selectionExpired))
    #expect(throws: AuthorityError.rejected) { try fixture.request(.arm(expectedRevision: policy.revision)) }
}

@Test @MainActor func daemonRechecksSessionAfterQueueHandoff() throws {
    let fixture = Fixture(); fixture.host.watcherStarted()
    _ = try fixture.select()
    fixture.active = false
    #expect(throws: PeerPolicyError.inactiveSession) { try fixture.request(.getDevices) }
    #expect(fixture.host.cache.load().session == .inactive)
    #expect(fixture.host.cache.load().issues.contains(.selectionExpired))
    fixture.active = true
    _ = try fixture.request(.getDevices)
    #expect(fixture.host.cache.load().session == .activeOwner)
    #expect(fixture.host.cache.load().issues.contains(.selectionExpired))
}

@Test @MainActor func expiredDaemonCommandCannotMutatePolicyAfterSlowReconciliation() throws {
    let fixture = Fixture(); fixture.host.watcherStarted()
    fixture.readDelay = 1_001
    #expect(throws: DaemonRuntimeError.expiredCommand) { try fixture.request(.getDevices) }
    #expect(fixture.host.cache.load().policyRevision == nil)
    let reads = fixture.reads
    #expect(throws: DaemonRuntimeError.expiredCommand) { try fixture.request(.arm(expectedRevision: 1), receivedAt: 100) }
    #expect(fixture.reads == reads && !fixture.host.cache.load().armIntent)
}

@Test @MainActor func frozenDaemonSnapshotCannotBeRenewedByXPCReads() throws {
    let fixture = Fixture(); fixture.host.watcherStarted(); fixture.host.pulse()
    let first = fixture.host.cache.load()
    fixture.now += 4_000
    for _ in 0..<20 { #expect(fixture.host.cache.load() == first) }
    #expect(first.displayStatus(at: fixture.now) == .error)
    #expect(first.validUntil <= fixture.now)
}

@Test @MainActor func failedDaemonEnumerationBlocksChoiceUntilFreshRestart() throws {
    let fixture = Fixture(); fixture.host.watcherStarted()
    _ = try fixture.select()
    fixture.readFails = true
    fixture.host.inventoryChanged()
    #expect(fixture.host.cache.load().issues.contains(.selectionExpired))
    #expect(throws: AuthorityError.unavailable) { try fixture.request(.getDevices) }
    fixture.readFails = false
    fixture.host.watcherStarted()
    _ = try fixture.request(.getDevices)
    #expect(fixture.host.cache.load().issues.contains(.selectionExpired))
    fixture.host.stop()
    #expect(throws: DaemonRuntimeError.stopped) { try fixture.request(.getDevices) }
}
