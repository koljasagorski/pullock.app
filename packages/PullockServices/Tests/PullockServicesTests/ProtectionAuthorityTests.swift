import Foundation
import PullockCore
import PullockIPC
@testable import PullockServices
import Testing

private let chosen = WireDevice(instance: 12, vendorID: 0x1234, productID: 0x4321, name: "Test stick")
private func owner() throws -> OwnerSessionPolicy { try OwnerSessionPolicy(uid: 501, auditSession: 42, active: true) }

private func prepared(live: Bool = false) throws -> ProtectionAuthority {
    let host = try ProtectionAuthority(capabilities: live ? .init() : .init(profile: .simulation, lock: .mockOnly))
    try host.bindOwner(owner(), now: 100)
    let state = host.snapshot(now: 100)
    try host.inventory([chosen], epoch: state.epoch, now: 100)
    let selection = try ConnectionIdentity(bootID: host.bootID, watcher: state.epoch.watcher,
        power: state.epoch.power, instance: chosen.instance)
    let enrollment = try Enrollment(id: UUID(), vendorID: chosen.vendorID, productID: chosen.productID, connection: selection)
    _ = try host.command(.configure(policy: ProtectionPolicy(revision: 1, enrollment: enrollment), expectedRevision: nil),
        role: .app, owner: owner(), now: 100)
    for component in HealthComponent.allCases { host.processed(component, now: 100) }
    return host
}

@Test func sessionReadinessCannotBeSpoofedByAppOrReplayedAcrossGenerations() throws {
    let host = try prepared()
    let generation = host.snapshot(now: 100).healthGeneration
    let ready = WirePayload.sessionReadiness(generation: generation, progress: 100, lockAvailable: true)
    #expect(throws: AuthorityError.unauthorized) { try host.command(ready, role: .app, owner: owner(), now: 100) }
    _ = try host.command(ready, role: .sessionAgent, owner: owner(), now: 100)
    #expect(throws: AuthorityError.rejected) { try host.command(ready, role: .sessionAgent, owner: owner(), now: 101) }
    try host.lifecycle(.willSleep, now: 102)
    #expect(throws: AuthorityError.rejected) { try host.command(ready, role: .sessionAgent, owner: owner(), now: 103) }
    #expect(host.snapshot(now: 103).issues.contains(.missingHealth(.lockPath)))
}

@Test func freshErrorSnapshotAllowsRepairWithoutRenewingStalePrerequisites() throws {
    let host = try prepared()
    let old = host.snapshot(now: 100)
    let current = host.snapshot(now: 4_000)
    #expect(old.validUntil <= 4_000)
    #expect(current.generatedAt == 4_000 && current.validUntil > 4_000)
    #expect(current.issues.contains(.staleHealth(.agent)))
    #expect(current.status == .error && !current.isProtected(at: 4_000))
}

@Test func authorityRequiresAuthenticatedOwnerAndSeparatesRoles() throws {
    let host = try ProtectionAuthority()
    #expect(throws: AuthorityError.unavailable) { try host.command(.getHealth, role: .app, owner: owner(), now: 100) }
    try host.bindOwner(owner(), now: 100)
    #expect(throws: AuthorityError.staleOwner) {
        try host.bindOwner(OwnerSessionPolicy(uid: 502, auditSession: 43, active: true), now: 100)
    }
    #expect(throws: AuthorityError.unauthorized) { try host.command(.arm(expectedRevision: 1), role: .sessionAgent, owner: owner(), now: 100) }
    #expect(throws: AuthorityError.unauthorized) {
        try host.command(.sessionHeartbeat(generation: 2, progress: 1), role: .app, owner: owner(), now: 100)
    }
    host.ownerBecameInactive(now: 101)
    #expect(throws: PeerPolicyError.inactiveSession) { try host.command(.getHealth, role: .app, owner: owner(), now: 101) }
}

@Test func authorityInventoryArmRemovalAndResultStayOneTransactionChain() throws {
    let host = try prepared()
    let inventory = try host.command(.getDevices, role: .app, owner: owner(), now: 100)
    guard case let .devices(devices, state) = inventory else { Issue.record("Expected authoritative inventory"); return }
    #expect(devices == [chosen] && state.bootID == host.bootID)
    _ = try host.command(.arm(expectedRevision: 1), role: .app, owner: owner(), now: 100)
    let effects = host.takeEffects()
    guard case let .requestInventory(epoch) = try #require(effects.last) else { Issue.record("Fresh inventory required"); return }
    try host.inventory([chosen], epoch: epoch, now: 100)
    #expect(host.snapshot(now: 100).status == .armed)
    host.removed(instance: chosen.instance, epoch: epoch, now: 101)
    let actions = host.takeEffects().compactMap { if case let .action(action) = $0 { action } else { nil } }
    let action = try #require(actions.first)
    #expect(actions.count == 1 && action.id.kind == .lock)
    #expect(throws: AuthorityError.rejected) {
        try host.command(.lockResult(result: ActionResult(id: action.id, outcome: .confirmed)), role: .sessionAgent, owner: owner(), now: 101)
    }
    _ = try host.command(.lockResult(result: ActionResult(id: action.id, outcome: .unknown)), role: .sessionAgent, owner: owner(), now: 101)
    #expect(host.snapshot(now: 101).lockOutcome == .unknown)
    _ = try host.command(.resetTrigger(id: action.id.trigger), role: .app, owner: owner(), now: 102)
    #expect(throws: AuthorityError.rejected) { try host.command(.arm(expectedRevision: 1), role: .app, owner: owner(), now: 102) }
}

@Test func unqualifiedLiveAuthorityNeverBecomesArmedOrEmitsAction() throws {
    let host = try prepared(live: true)
    _ = try host.command(.arm(expectedRevision: 1), role: .app, owner: owner(), now: 100)
    let epoch = host.snapshot(now: 100).epoch
    _ = host.takeEffects()
    try host.inventory([chosen], epoch: epoch, now: 100)
    let snapshot = host.snapshot(now: 100)
    #expect(snapshot.status == .error && !snapshot.isProtected(at: 100))
    host.removed(instance: chosen.instance, epoch: epoch, now: 101)
    #expect(host.takeEffects().allSatisfy { if case .action = $0 { false } else { true } })
}

@Test func authorityRejectsStaleInventoryAndCannotRearmAcrossPowerBoundary() throws {
    let host = try prepared()
    let old = host.snapshot(now: 100).epoch
    try host.lifecycle(.willSleep, now: 101)
    try host.lifecycle(.didWake, now: 102)
    #expect(throws: AuthorityError.rejected) { try host.inventory([chosen], epoch: old, now: 102) }
    #expect(throws: AuthorityError.unavailable) { try host.command(.getDevices, role: .app, owner: owner(), now: 102) }
    try host.inventory([chosen], epoch: host.snapshot(now: 102).epoch, now: 102)
    #expect(throws: AuthorityError.rejected) { try host.command(.arm(expectedRevision: 1), role: .app, owner: owner(), now: 102) }
}

@Test func authorityCannotUseLifecycleBoundaryToInjectUserOrDeviceCommands() throws {
    let host = try prepared()
    #expect(throws: AuthorityError.unauthorized) { try host.lifecycle(.arm(expectedRevision: 1), now: 100) }
    #expect(throws: AuthorityError.invalidInventory) {
        try host.inventory([chosen, chosen], epoch: host.snapshot(now: 100).epoch, now: 100)
    }
    #expect(throws: AuthorityError.unavailable) { try host.command(.arm(expectedRevision: 1), role: .app, owner: owner(), now: 100) }
}

@Test func stalledEffectConsumerStopsArmingWithoutDiscardingLockRequests() throws {
    let host = try prepared()
    var refused = false
    for _ in 0..<80 {
        do { _ = try host.command(.arm(expectedRevision: 1), role: .app, owner: owner(), now: 100) }
        catch AuthorityError.unavailable { refused = true; break }
        let state = host.snapshot(now: 100)
        try host.inventory([chosen], epoch: state.epoch, now: 100)
        host.processed(.watcher, condition: .failed, now: 100)
        _ = try host.command(.disarm(expectedArming: state.epoch.arming), role: .app, owner: owner(), now: 100)
        for component in HealthComponent.allCases { host.processed(component, now: 100) }
    }
    #expect(refused)
    #expect(host.snapshot(now: 100).status != .armed)
    let pending = host.takeEffects()
    let actions = pending.compactMap { if case let .action(action) = $0 { action.id } else { nil } }
    #expect(!actions.isEmpty && pending.count <= 66)
    #expect(Set(actions).count == actions.count)
    #expect(throws: AuthorityError.unavailable) { try host.command(.arm(expectedRevision: 1), role: .app, owner: owner(), now: 100) }
}
