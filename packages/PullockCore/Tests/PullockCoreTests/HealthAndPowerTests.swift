import Testing
import PullockCore

@Test func expiredHealthLocksOnceAndKeepsRemovalAuthority() throws {
    var f = try Fixture(mode: .lockAndShutdown)
    f.arm()
    f.time += 3_000
    let timeout = f.send(.tick)
    #expect(timeout.snapshot.status == .error)
    #expect(timeout.actions.map(\.id.kind) == [.lock])
    #expect(timeout.snapshot.seenKeySinceArming)
    let again = f.send(.tick)
    #expect(again.actions.isEmpty)
    let removal = f.send(.removed(instance: 10, epoch: f.epoch))
    #expect(removal.snapshot.status == .triggered)
    #expect(removal.actions.map(\.id.kind) == [.lock, .shutdown])
}

@Test func heartbeatWithoutProgressDoesNotRenewLease() throws {
    var f = try Fixture()
    f.arm()
    f.time += 2_999
    let frozen = f.send(.health(HealthObservation(.watcher, generation: f.snapshot.healthGeneration, progress: 1)))
    #expect(frozen.rejection == .noProgress)
    f.time += 1
    let stale = f.send(.tick)
    #expect(stale.snapshot.issues.contains(.staleHealth(.watcher)))
    #expect(stale.snapshot.status == .error)
}

@Test func healthRecoveryRequiresExplicitRearmingAndFreshInventory() throws {
    var f = try Fixture()
    f.arm()
    f.send(.health(HealthObservation(.agent, generation: f.snapshot.healthGeneration, progress: 2, condition: .failed)))
    f.progress[.agent] = 2
    f.healthy()
    #expect(f.snapshot.status == .error)
    let reset = f.send(.arm(expectedRevision: 1))
    #expect(reset.snapshot.status == .waiting)
    f.send(.inventory([Fixture.key], f.epoch))
    #expect(f.snapshot.status == .armed)
}

@Test func failedObservationCannotRewindProgress() throws {
    var f = try Fixture()
    f.arm()
    f.send(.health(HealthObservation(.watcher, generation: f.snapshot.healthGeneration, progress: 10)))
    let oldFailure = f.send(.health(HealthObservation(.watcher, generation: f.snapshot.healthGeneration,
        progress: 1, condition: .failed)))
    #expect(oldFailure.rejection == .noProgress)
    let oldHealthy = f.send(.health(HealthObservation(.watcher, generation: f.snapshot.healthGeneration, progress: 9)))
    #expect(oldHealthy.rejection == .noProgress)
}

@Test func sleepDiscardsPresenceAndRequiresNewHealthGeneration() throws {
    var f = try Fixture(mode: .lockAndShutdown)
    f.arm()
    let oldEpoch = f.epoch
    let oldGeneration = f.snapshot.healthGeneration
    let sleep = f.send(.willSleep)
    #expect(sleep.snapshot.status == .waiting)
    #expect(!sleep.snapshot.seenKeySinceArming)
    let oldRemoval = f.send(.removed(instance: 10, epoch: oldEpoch))
    #expect(oldRemoval.rejection == .staleEpoch)
    #expect(oldRemoval.actions.isEmpty)
    f.send(.didWake)
    let staleHealth = f.send(.health(HealthObservation(.watcher, generation: oldGeneration, progress: 99)))
    #expect(staleHealth.rejection == .staleHealthGeneration)
    f.healthy()
    let absent = f.send(.inventory([], f.epoch))
    #expect(absent.snapshot.status == .waiting)
    #expect(absent.actions.map(\.id.kind) == [.lock])
    #expect(absent.actions[0].id.cause == .wakeWithoutKey)
    #expect(absent.snapshot.trigger == nil)
}

@Test func normalWakeCanResumeOnlyAfterFreshPresenceAndHealth() throws {
    var f = try Fixture()
    f.arm()
    f.send(.willSleep)
    f.send(.willWake)
    let earlyPresence = f.send(.inventory([Fixture.key], f.epoch))
    #expect(earlyPresence.rejection == .invalidPowerTransition)
    f.send(.didWake)
    f.send(.inventory([Fixture.key], f.epoch))
    #expect(f.snapshot.status != .armed)
    f.healthy()
    #expect(f.snapshot.status == .armed)
}

@Test func displaySleepDoesNotDisableRemoval() throws {
    var f = try Fixture(mode: .lockAndShutdown)
    f.arm()
    f.send(.displaySleep)
    #expect(f.snapshot.status == .armed)
    let removal = f.send(.removed(instance: 10, epoch: f.epoch))
    #expect(removal.actions.map(\.id.kind) == [.lock, .shutdown])
}

@Test func oppositePowerOrdersExposeTheUnresolvedHardwareBoundary() throws {
    var sleepFirst = try Fixture(mode: .lockAndShutdown)
    sleepFirst.arm()
    let epoch = sleepFirst.epoch
    sleepFirst.send(.willSleep)
    let lateRemoval = sleepFirst.send(.removed(instance: 10, epoch: epoch))
    #expect(lateRemoval.actions.isEmpty)
    var removalFirst = try Fixture(mode: .lockAndShutdown)
    removalFirst.arm()
    let earlyRemoval = removalFirst.send(.removed(instance: 10, epoch: removalFirst.epoch))
    removalFirst.send(.willSleep)
    #expect(earlyRemoval.actions.map(\.id.kind) == [.lock, .shutdown])
    #expect(removalFirst.snapshot.trigger != nil)
    // Serialization cannot establish which physical event actually happened first.
}

@Test func inactiveOwnerAndWatcherRestartRequireExplicitRecovery() throws {
    for event in [ProtectionEvent.session(.inactive), .watcherRestarted] {
        var f = try Fixture(mode: .lockAndShutdown)
        f.arm()
        let old = f.epoch
        let boundary = f.send(event)
        #expect(boundary.actions.map(\.id.kind) == [.lock])
        #expect(!boundary.snapshot.seenKeySinceArming)
        let removal = f.send(.removed(instance: 10, epoch: old))
        #expect(removal.actions.isEmpty)
        f.send(.session(.activeOwner))
        f.healthy()
        f.send(.inventory([Fixture.key], f.epoch))
        #expect(f.snapshot.status == .error)
        f.arm()
        #expect(f.snapshot.status == .armed)
    }
}

@Test func clockRollbackFailsClosedWithoutShutdown() throws {
    var f = try Fixture(mode: .lockAndShutdown)
    f.arm()
    f.time -= 1
    let result = f.send(.tick)
    #expect(result.snapshot.status == .error)
    #expect(result.snapshot.issues.contains(.monotonicClockFailure))
    #expect(result.actions.map(\.id.kind) == [.lock])
}

@Test func armingDuringSleepDefersInventoryUntilWake() throws {
    var f = try Fixture()
    f.send(.willSleep)
    let arm = f.send(.arm(expectedRevision: 1))
    #expect(arm.snapshot.status == .waiting)
    #expect(arm.effects.isEmpty)
    let wake = f.send(.didWake)
    #expect(wake.effects == [.requestInventory(f.epoch)])
    #expect(!wake.snapshot.seenKeySinceArming)
}
