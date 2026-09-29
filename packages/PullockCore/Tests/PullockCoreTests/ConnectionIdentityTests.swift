import Foundation
import PullockCore
import Testing

private let stick = DeviceObservation(instance: 73, vendorID: 0x1234, productID: 0x4321, serial: nil)

private func selectedFixture() throws -> Fixture {
    var fixture = try Fixture()
    fixture.send(.inventory([stick], fixture.epoch))
    let connection = try ConnectionIdentity(bootID: Fixture.boot, watcher: fixture.epoch.watcher,
        power: fixture.epoch.power, instance: stick.instance)
    let enrollment = try Enrollment(id: UUID(), vendorID: stick.vendorID, productID: stick.productID, connection: connection)
    #expect(fixture.send(.configure(try ProtectionPolicy(revision: 2, enrollment: enrollment), expectedRevision: 1)).accepted)
    return fixture
}

@Test func selectedSeriallessConnectionArmsAndTriggersOnce() throws {
    var fixture = try selectedFixture()
    #expect(fixture.send(.arm(expectedRevision: 2)).accepted)
    #expect(fixture.send(.inventory([stick], fixture.epoch)).snapshot.status == .armed)
    #expect(fixture.send(.removed(instance: 999, epoch: fixture.epoch)).actions.isEmpty)
    let removal = fixture.send(.removed(instance: stick.instance, epoch: fixture.epoch))
    #expect(removal.snapshot.status == .triggered)
    #expect(removal.actions.map(\.id.kind) == [.lock])
    #expect(fixture.send(.removed(instance: stick.instance, epoch: fixture.epoch)).actions.isEmpty)
}

@Test func connectionChoiceRequiresCurrentDaemonInventoryAndEpoch() throws {
    var fixture = try Fixture()
    for boot in [Fixture.boot, UUID()] {
        let selection = try ConnectionIdentity(bootID: boot, watcher: fixture.epoch.watcher, power: 0, instance: stick.instance)
        let enrollment = try Enrollment(id: UUID(), vendorID: stick.vendorID, productID: stick.productID, connection: selection)
        #expect(fixture.send(.configure(try ProtectionPolicy(revision: 2, enrollment: enrollment), expectedRevision: 1)).rejection == .invalidPolicy)
    }
    fixture.send(.inventory([stick], fixture.epoch))
    let selection = try ConnectionIdentity(bootID: UUID(), watcher: fixture.epoch.watcher, power: 0, instance: stick.instance)
    let enrollment = try Enrollment(id: UUID(), vendorID: stick.vendorID, productID: stick.productID, connection: selection)
    #expect(fixture.send(.configure(try ProtectionPolicy(revision: 2, enrollment: enrollment), expectedRevision: 1)).rejection == .invalidPolicy)
}

@Test func replacementAndMissingSnapshotExpireConnectionChoice() throws {
    for replacement in [[], [DeviceObservation(instance: 74, vendorID: stick.vendorID, productID: stick.productID, serial: nil)]] {
        var fixture = try selectedFixture()
        fixture.send(.inventory(replacement, fixture.epoch))
        fixture.send(.inventory([stick], fixture.epoch))
        #expect(fixture.send(.arm(expectedRevision: 2)).rejection == .invalidPolicy)
        #expect(fixture.snapshot.issues.contains(.selectionExpired))
    }
}

@Test func sleepSessionAndWatcherChangesRequireNewConnectionSelection() throws {
    var sleep = try selectedFixture()
    sleep.send(.willSleep); sleep.send(.didWake); sleep.healthy()
    sleep.send(.inventory([stick], sleep.epoch))
    #expect(sleep.send(.arm(expectedRevision: 2)).rejection == .invalidPolicy)
    var session = try selectedFixture()
    session.send(.session(.inactive)); session.send(.session(.activeOwner)); session.healthy()
    session.send(.inventory([stick], session.epoch))
    #expect(session.send(.arm(expectedRevision: 2)).rejection == .invalidPolicy)
    var watcher = try selectedFixture()
    watcher.send(.watcherRestarted); watcher.healthy()
    watcher.send(.inventory([stick], watcher.epoch))
    #expect(watcher.send(.arm(expectedRevision: 2)).rejection == .invalidPolicy)
}

@Test func removalBeforeArmCannotBecomeProtectionAfterReconnect() throws {
    var fixture = try selectedFixture()
    #expect(fixture.send(.removed(instance: stick.instance, epoch: fixture.epoch)).actions.isEmpty)
    fixture.send(.attached(stick, fixture.epoch))
    #expect(fixture.send(.arm(expectedRevision: 2)).rejection == .invalidPolicy)
}
