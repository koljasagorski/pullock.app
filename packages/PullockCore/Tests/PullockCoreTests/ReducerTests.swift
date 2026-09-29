import Foundation
import Testing
import PullockCore
import PullockSimulation

@Test func startupAndArmingWithoutKeyNeverAct() throws {
    var f = try Fixture(mode: .lockAndShutdown)
    #expect(f.snapshot.status == .disarmed)
    let wait = f.arm([])
    #expect(wait.snapshot.status == .waiting)
    #expect(!wait.snapshot.seenKeySinceArming)
    let absent = f.send(.removed(instance: 10, epoch: f.epoch))
    #expect(absent.actions.isEmpty)
    #expect(absent.snapshot.trigger == nil)
}

@Test func armRequiresNewInventoryAndAcknowledgedRevision() throws {
    var f = try Fixture()
    f.send(.inventory([Fixture.key], f.epoch))
    let staleRevision = f.send(.arm(expectedRevision: 2))
    #expect(staleRevision.rejection == .revisionConflict)
    let oldEpoch = f.epoch
    let intent = f.send(.arm(expectedRevision: 1))
    #expect(intent.snapshot.status == .waiting)
    #expect(intent.effects == [.requestInventory(f.epoch)])
    let staleInventory = f.send(.inventory([Fixture.key], oldEpoch))
    #expect(staleInventory.rejection == .staleEpoch)
    #expect(f.snapshot.status != .armed)
    f.send(.inventory([Fixture.key], f.epoch))
    #expect(f.snapshot.status == .armed)
}

@Test func removalOrdersEffectsWithoutWaitingForAnAcknowledgement() throws {
    var f = try Fixture(mode: .lockAndShutdown)
    f.arm()
    let removed = f.send(.removed(instance: 10, epoch: f.epoch))
    #expect(removed.snapshot.status == .triggered)
    #expect(removed.actions.map(\.id.kind) == [.lock, .shutdown])
    #expect(removed.snapshot.lockOutcome == nil)
    #expect(removed.snapshot.shutdownOutcome == nil)
}

@Test func secondKeyAndUnboundRemovalDoNotTrigger() throws {
    var f = try Fixture(mode: .lockAndShutdown)
    f.arm()
    f.send(.attached(DeviceObservation(instance: 11, vendorID: 0x1050,
        productID: 0x0407, serial: "OTHER"), f.epoch))
    let other = f.send(.removed(instance: 11, epoch: f.epoch))
    #expect(other.actions.isEmpty)
    #expect(f.snapshot.status == .armed)
}

@Test func triggerSurvivesReconnectDisarmAndDuplicateRemoval() throws {
    var f = try Fixture(mode: .lockAndShutdown)
    f.arm()
    let first = f.send(.removed(instance: 10, epoch: f.epoch))
    let originalTrigger = first.snapshot.trigger
    let duplicate = f.send(.removed(instance: 10, epoch: f.epoch))
    f.send(.attached(DeviceObservation(instance: 12, vendorID: 0x1050,
        productID: 0x0407, serial: Fixture.serial), f.epoch))
    let disarm = f.send(.disarm(expectedArming: f.epoch.arming))
    #expect(duplicate.actions.isEmpty)
    #expect(disarm.rejection == .triggerLatched)
    #expect(f.snapshot.trigger == originalTrigger)
    #expect(f.snapshot.status == .triggered)
}

@Test func committedDisarmWinsBeforeRemoval() throws {
    var f = try Fixture(mode: .lockAndShutdown)
    f.arm()
    let oldEpoch = f.epoch
    f.send(.disarm(expectedArming: oldEpoch.arming))
    let result = f.send(.removed(instance: 10, epoch: oldEpoch))
    #expect(result.rejection == .staleEpoch)
    #expect(result.actions.isEmpty)
    #expect(f.snapshot.status == .disarmed)
}

@Test func restartNeverRestoresPresenceOrReplaysAnAction() throws {
    var f = try Fixture(mode: .lockAndShutdown)
    f.arm()
    let old = f.send(.removed(instance: 10, epoch: f.epoch))
    let newBoot = UUID()
    var restart = try ProtectionReducer(bootID: newBoot)
    let replay = restart.process(EventEnvelope(bootID: Fixture.boot, source: .usb,
        sequence: 100, observedAt: 100, event: .removed(instance: 10, epoch: f.epoch)), at: 100)
    #expect(old.snapshot.trigger != nil)
    #expect(replay.rejection == .wrongBoot)
    #expect(replay.actions.isEmpty)
    #expect(!restart.snapshot.seenKeySinceArming)
}

@Test func liveModeRejectsMockQualificationsAndUnavailableLock() throws {
    for qualification in [ActionQualification.mockOnly, .unavailable] {
        var f = try Fixture(profile: .live, lock: qualification, shutdown: .qualified)
        f.arm()
        #expect(f.snapshot.status == .error)
        #expect(f.snapshot.issues.contains(.lockUnqualified))
        let removed = f.send(.removed(instance: 10, epoch: f.epoch))
        #expect(removed.actions.isEmpty)
    }
}

@Test func shutdownNeedsAcknowledgementAndItsOwnQualification() throws {
    var noConsent = try Fixture(mode: .lockAndShutdown, acknowledgeShutdown: false)
    noConsent.arm()
    #expect(noConsent.snapshot.issues.contains(.shutdownNotAcknowledged))
    #expect(!noConsent.snapshot.seenKeySinceArming)
    var noAdapter = try Fixture(mode: .lockAndShutdown, shutdown: .unavailable)
    noAdapter.arm()
    #expect(noAdapter.snapshot.issues.contains(.shutdownUnqualified))
}

@Test func lockOnlyDoesNotRequireShutdownHealth() throws {
    var f = try Fixture(shutdown: .unavailable)
    f.send(.health(HealthObservation(.shutdownPath, generation: f.snapshot.healthGeneration,
        progress: 2, condition: .failed)))
    f.arm()
    #expect(f.snapshot.status == .armed)
}

@Test func snapshotNeverExposesIdentityOrPretendsSimulationIsProtection() throws {
    var f = try Fixture()
    f.arm()
    let data = try JSONEncoder().encode(f.snapshot)
    #expect(!String(decoding: data, as: UTF8.self).contains(Fixture.serial))
    #expect(!f.snapshot.isProtected(at: f.time))
    var liveFixture = try Fixture(profile: .live, lock: .qualified)
    liveFixture.arm()
    let snapshot = liveFixture.snapshot
    #expect(snapshot.isProtected(at: liveFixture.time))
    #expect(!snapshot.isProtected(at: snapshot.validUntil))
    #expect(!snapshot.isProtected(at: snapshot.generatedAt - 1))
    #expect(snapshot.displayStatus(at: snapshot.validUntil) == .error)
}

@Test func actionResultsAreBoundToAnIssuedRequestAndCannotRegress() throws {
    var f = try Fixture(mode: .lockAndShutdown)
    f.arm()
    let triggered = f.send(.removed(instance: 10, epoch: f.epoch))
    let lock = try #require(triggered.actions.first)
    let id = try #require(f.snapshot.trigger)
    let premature = f.send(.resetTrigger(id))
    #expect(premature.rejection == .actionNotComplete)
    f.send(.actionResult(ActionResult(id: lock.id, outcome: .submitted)))
    #expect(f.snapshot.lockOutcome == .submitted)
    f.send(.actionResult(ActionResult(id: lock.id, outcome: .simulated)))
    let downgrade = f.send(.actionResult(ActionResult(id: lock.id, outcome: .failed)))
    #expect(downgrade.rejection == .invalidActionResult)
    let shutdownPending = f.send(.resetTrigger(id))
    #expect(shutdownPending.rejection == .actionNotComplete)
    f.send(.actionResult(ActionResult(id: triggered.actions[1].id, outcome: .failed)))
    let reset = f.send(.resetTrigger(id))
    #expect(reset.accepted)
    #expect(f.snapshot.status == .disarmed)
    #expect(!f.snapshot.armIntent)
}

@Test func simulatedResultCannotConfirmLiveAction() throws {
    var f = try Fixture(profile: .live, lock: .qualified)
    f.arm()
    let triggered = f.send(.removed(instance: 10, epoch: f.epoch))
    let result = f.send(.actionResult(ActionResult(id: triggered.actions[0].id, outcome: .simulated)))
    #expect(result.rejection == .invalidActionResult)
    #expect(f.snapshot.lockOutcome == nil)
}

@Test func mockExecutorIsIdempotentAndNeverClaimsRealSuccess() throws {
    var f = try Fixture(mode: .lockAndShutdown)
    f.arm()
    let triggered = f.send(.removed(instance: 10, epoch: f.epoch))
    var mock = MockProtectionActions()
    for action in triggered.actions {
        let first = mock.submit(action)
        let second = mock.submit(action)
        #expect(first == second)
        #expect(first.outcome == .simulated)
    }
    #expect(mock.requests.count == 2)
}

@Test func allDevelopmentScenariosStayExplicitlySimulated() throws {
    for scenario in SimulationScenario.allCases {
        let steps = try SimulationRunner.run(scenario)
        #expect(!steps.isEmpty)
        #expect(steps.allSatisfy { $0.snapshot.profile == .simulation && !$0.snapshot.isProtected(at: $0.snapshot.generatedAt) })
    }
}
