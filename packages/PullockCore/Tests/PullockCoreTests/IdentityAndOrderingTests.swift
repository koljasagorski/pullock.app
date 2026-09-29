import Foundation
import Testing
import PullockCore

@Test func absentOrDifferentSerialCannotBind() throws {
    for serial: String? in [nil, "WRONG", Fixture.serial.lowercased(), Fixture.serial + " "] {
        var f = try Fixture()
        f.arm([DeviceObservation(instance: 10, vendorID: 0x1050, productID: 0x0407, serial: serial)])
        #expect(f.snapshot.status == .waiting)
        #expect(!f.snapshot.seenKeySinceArming)
        let removal = f.send(.removed(instance: 10, epoch: f.epoch))
        #expect(removal.actions.isEmpty)
    }
}

@Test func knownPIDVariantIsAllowedButUnknownPIDIsRejected() throws {
    var known = try Fixture()
    known.arm([DeviceObservation(instance: 10, vendorID: 0x1050, productID: 0x0403, serial: Fixture.serial)])
    #expect(known.snapshot.status == .armed)
    var unknown = try Fixture()
    unknown.arm([DeviceObservation(instance: 10, vendorID: 0x1050, productID: 0x9999, serial: Fixture.serial)])
    #expect(unknown.snapshot.status == .error)
    #expect(unknown.snapshot.issues.contains(.unknownProduct))
}

@Test func duplicateIdentityLocksAndDoesNotReplaceOriginalBinding() throws {
    var f = try Fixture(mode: .lockAndShutdown)
    f.arm()
    let duplicate = f.send(.attached(DeviceObservation(instance: 11, vendorID: 0x1050,
        productID: 0x0407, serial: Fixture.serial), f.epoch))
    #expect(duplicate.snapshot.status == .error)
    #expect(duplicate.actions.map(\.id.kind) == [.lock])
    let originalRemoval = f.send(.removed(instance: 10, epoch: f.epoch))
    #expect(originalRemoval.snapshot.status == .triggered)
    #expect(originalRemoval.actions.map(\.id.kind) == [.lock, .shutdown])
}

@Test func duplicateBeforeBindingRequiresExplicitRecovery() throws {
    var f = try Fixture()
    f.arm([Fixture.key, DeviceObservation(instance: 11, vendorID: 0x1050,
        productID: 0x0407, serial: Fixture.serial)])
    f.send(.removed(instance: 11, epoch: f.epoch))
    #expect(f.snapshot.status == .error)
    #expect(!f.snapshot.seenKeySinceArming)
    f.arm()
    #expect(f.snapshot.status == .armed)
}

@Test func disappearingSnapshotIsAnErrorNotAConfirmedRemoval() throws {
    var f = try Fixture(mode: .lockAndShutdown)
    f.arm()
    let snapshot = f.send(.inventory([], f.epoch))
    #expect(snapshot.snapshot.status == .error)
    #expect(snapshot.snapshot.issues.contains(.inventoryMismatch))
    #expect(snapshot.actions.map(\.id.kind) == [.lock])
    #expect(snapshot.snapshot.trigger == nil)
}

@Test func malformedAndOversizedInventoryNeverArms() throws {
    let invalid = DeviceObservation(instance: 10, vendorID: 0x1050, productID: 0x0407, serial: "bad\nserial")
    for devices in [[invalid], [Fixture.key, Fixture.key], Array(repeating: Fixture.key, count: 129)] {
        var f = try Fixture()
        f.arm(devices)
        #expect(f.snapshot.status == .error)
        #expect(!f.snapshot.seenKeySinceArming)
    }
}

@Test func enrollmentAndPolicyAreRevalidatedAfterDecoding() throws {
    let invalidSerial = "{\"id\":\"00000000-0000-0000-0000-000000000001\",\"vendorID\":4176,\"acceptedProductIDs\":[1031],\"serial\":\"\"}"
    let enrollment = try JSONDecoder().decode(Enrollment.self, from: Data(invalidSerial.utf8))
    #expect(throws: ValidationError.self) { try enrollment.validate() }
    let invalidPolicy = "{\"revision\":2,\"mode\":\"lock\",\"shutdownAcknowledged\":false,\"enrollment\":\(invalidSerial)}"
    let policy = try JSONDecoder().decode(ProtectionPolicy.self, from: Data(invalidPolicy.utf8))
    var f = try Fixture()
    let result = f.send(.configure(policy, expectedRevision: 1))
    #expect(result.rejection == .invalidPolicy)
    #expect(f.snapshot.policyRevision == 1)
}

@Test func activePolicyCannotBeReplaced() throws {
    var f = try Fixture()
    f.arm()
    let enrollment = try Enrollment(id: UUID(), vendorID: 0x1050, acceptedProductIDs: [0x0407], serial: "NEW")
    let policy = try ProtectionPolicy(revision: 2, enrollment: enrollment)
    let result = f.send(.configure(policy, expectedRevision: 1))
    #expect(result.rejection == .notDisarmed)
    #expect(f.snapshot.policyRevision == 1)
}

@Test func staleFutureAndMisroutedEnvelopesAreRejected() throws {
    var f = try Fixture()
    f.arm()
    let event = ProtectionEvent.removed(instance: 10, epoch: f.epoch)
    let replay = f.reducer.process(EventEnvelope(bootID: Fixture.boot, source: .usb,
        sequence: f.sequences[.usb]!, observedAt: f.time, event: event), at: f.time)
    #expect(replay.rejection == .staleSequence)
    let future = f.reducer.process(EventEnvelope(bootID: Fixture.boot, source: .usb,
        sequence: 100, observedAt: f.time + 1, event: event), at: f.time)
    #expect(future.rejection == .futureEvent)
    let misrouted = f.reducer.process(EventEnvelope(bootID: Fixture.boot, source: .user,
        sequence: 100, observedAt: f.time, event: event), at: f.time)
    #expect(misrouted.rejection == .wrongSource)
    #expect(f.snapshot.status == .armed)
}

@Test func deterministicMixedSequencesPreserveSafetyInvariants() throws {
    // Reproducible generated schedules, no random sleeps or real system adapters.
    for seed in UInt64(1)...100 {
        var random = seed
        var f = try Fixture(mode: .lockAndShutdown)
        var shutdowns: Set<TriggerID> = []
        for _ in 0..<100 {
            random = random &* 6_364_136_223_846_793_005 &+ 1
            let previous = f.snapshot
            let event: ProtectionEvent
            switch random % 12 {
            case 0: event = .arm(expectedRevision: 1)
            case 1: event = .inventory([Fixture.key], f.epoch)
            case 2: event = .inventory([], f.epoch)
            case 3: event = .removed(instance: 10, epoch: f.epoch)
            case 4: event = .removed(instance: 99, epoch: f.epoch)
            case 5: event = .willSleep
            case 6: event = .didWake
            case 7: event = .disarm(expectedArming: f.epoch.arming)
            case 8: event = .session(.inactive)
            case 9: event = .session(.activeOwner)
            case 10: event = .watcherRestarted
            default: f.time += 1_000; event = .tick
            }
            let transition = f.send(event)
            let state = transition.snapshot
            if state.status == .armed {
                #expect(state.seenKeySinceArming && state.armIntent)
                #expect(state.issues.isEmpty && state.matchingDeviceCount == 1)
                #expect(state.power == .awake && state.session == .activeOwner)
                #expect(state.trigger == nil)
            }
            if previous.trigger != nil { #expect(state.trigger == previous.trigger) }
            for action in transition.actions where action.id.kind == .shutdown {
                #expect(previous.seenKeySinceArming && previous.armIntent)
                #expect(previous.power == .awake && previous.session == .activeOwner)
                #expect(state.trigger == action.id.trigger)
                #expect(!shutdowns.contains(action.id.trigger))
                shutdowns.insert(action.id.trigger)
                if case .removed(instance: 10, epoch: previous.epoch) = event {} else {
                    Issue.record("Shutdown effect without matching removal")
                }
            }
            // Restore test health periodically without silently resetting recovery/epochs.
            if random % 5 == 0 { f.healthy() }
        }
    }
}
