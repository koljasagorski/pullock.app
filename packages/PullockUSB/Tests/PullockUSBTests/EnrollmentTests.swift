import Foundation
import PullockCore
import PullockUSB
import Testing

private let profile = QualifiedUSBProfile(vendorID: 0x1050, productIDs: [0x0407, 0x0401])
private func device(_ instance: UInt64 = 1, serial: SerialEvidence = .presentUnqualified(value: "TEST-123", sources: ["fixture"]), product: UInt16 = 0x0407) -> USBDevice {
    USBDevice(instance: instance, vendorID: 0x1050, productID: product, serial: serial)
}
private func review(_ watcher: UUID) throws -> EnrollmentReview {
    try EnrollmentReview(candidate: 1, inventory: [device()], watcher: watcher, disarmed: true, qualifiedProfiles: [profile])
}

@Test func descriptorEvidenceNeverQualifiesHardwareByItself() {
    #expect(EnrollmentReview.blocker(candidate: 1, inventory: [device()], qualifiedProfiles: []) == .unqualifiedProfile)
    #expect(EnrollmentReview.blocker(candidate: 1, inventory: [device()], qualifiedProfiles: [profile]) == .reconnectRequired)
}

@Test func serialProblemsAreExplainedWithoutFallbackIdentity() {
    for (serial, blocker): (SerialEvidence, EnrollmentBlocker) in [(.missing, .missingSerial), (.invalid, .invalidSerial), (.conflicting, .conflictingSerial)] {
        #expect(EnrollmentReview.blocker(candidate: 1, inventory: [device(serial: serial)], qualifiedProfiles: [profile]) == blocker)
    }
}

@Test func enrollmentRequiresDisarmedSelection() {
    #expect(throws: EnrollmentBlocker.notDisarmed) {
        try EnrollmentReview(candidate: 1, inventory: [device()], watcher: UUID(), disarmed: false, qualifiedProfiles: [profile])
    }
    #expect(EnrollmentReview.blocker(candidate: 8, inventory: [device()], qualifiedProfiles: [profile]) == .candidateMissing)
}

@Test func duplicateOrInvalidInventoryCannotStartReview() {
    #expect(EnrollmentReview.blocker(candidate: 1, inventory: [device(), device(2)], qualifiedProfiles: [profile]) == .duplicateIdentity)
    for inventory in [[device(), device()], [device(0)], (1...129).map { device(UInt64($0)) }] {
        #expect(EnrollmentReview.blocker(candidate: 1, inventory: inventory, qualifiedProfiles: [profile]) == .invalidInventory)
    }
    let bad = QualifiedUSBProfile(vendorID: 0x1050, productIDs: [0, 0x0407])
    #expect(EnrollmentReview.blocker(candidate: 1, inventory: [device()], qualifiedProfiles: [bad]) == .unqualifiedProfile)
}

@Test func sameInstanceIsNotAReconnect() throws {
    let watcher = UUID()
    var state = try review(watcher)
    #expect(throws: EnrollmentBlocker.reconnectRequired) { try state.observeReconnect(inventory: [device(2)], watcher: watcher) }
    try state.observeRemoval(instance: 1, watcher: watcher)
    #expect(throws: EnrollmentBlocker.reconnectRequired) { try state.observeReconnect(inventory: [device()], watcher: watcher) }
    #expect(throws: EnrollmentBlocker.reconnectRequired) { try state.enrollment(id: UUID(), inventory: [device()], watcher: watcher, disarmed: true) }
}

@Test func qualifiedReconnectProducesExactEnrollment() throws {
    let watcher = UUID(), id = UUID()
    var state = try review(watcher)
    try state.observeRemoval(instance: 1, watcher: watcher)
    let reattached = device(2, product: 0x0401)
    try state.observeReconnect(inventory: [reattached], watcher: watcher)
    let result = try state.enrollment(id: id, inventory: [reattached], watcher: watcher, disarmed: true)
    #expect(result.id == id)
    #expect(result.serial == "TEST-123")
    #expect(result.acceptedProductIDs == [0x0407, 0x0401])
    #expect(throws: EnrollmentBlocker.notDisarmed) { try state.enrollment(id: id, inventory: [reattached], watcher: watcher, disarmed: false) }
    #expect(throws: EnrollmentBlocker.reconnectRequired) { try state.enrollment(id: id, inventory: [], watcher: watcher, disarmed: true) }
}

@Test func wrongKeyAndUnknownProductCannotCompleteReview() throws {
    let watcher = UUID()
    var state = try review(watcher)
    #expect(throws: EnrollmentBlocker.wrongInstance) { try state.observeRemoval(instance: 99, watcher: watcher) }
    try state.observeRemoval(instance: 1, watcher: watcher)
    #expect(throws: EnrollmentBlocker.reconnectRequired) {
        try state.observeReconnect(inventory: [device(2, serial: .presentUnqualified(value: "OTHER", sources: ["fixture"]))], watcher: watcher)
    }
    #expect(throws: EnrollmentBlocker.unqualifiedProfile) { try state.observeReconnect(inventory: [device(2, product: 0x9999)], watcher: watcher) }
}

@Test func ambiguityClearsPreviousReconnectProof() throws {
    let watcher = UUID()
    var state = try review(watcher)
    try state.observeRemoval(instance: 1, watcher: watcher)
    try state.observeReconnect(inventory: [device(2)], watcher: watcher)
    #expect(throws: EnrollmentBlocker.duplicateIdentity) { try state.observeReconnect(inventory: [device(2), device(3)], watcher: watcher) }
    #expect(throws: EnrollmentBlocker.reconnectRequired) { try state.enrollment(id: UUID(), inventory: [device(2)], watcher: watcher, disarmed: true) }
}

@Test func finalInventoryCannotSubstituteOrDuplicateProof() throws {
    let watcher = UUID()
    var state = try review(watcher)
    try state.observeRemoval(instance: 1, watcher: watcher)
    try state.observeReconnect(inventory: [device(2)], watcher: watcher)
    #expect(throws: EnrollmentBlocker.duplicateIdentity) { try state.enrollment(id: UUID(), inventory: [device(2), device(3)], watcher: watcher, disarmed: true) }
    #expect(throws: EnrollmentBlocker.reconnectRequired) { try state.enrollment(id: UUID(), inventory: [device(3)], watcher: watcher, disarmed: true) }
}

@Test func watcherChangePermanentlyInvalidatesReview() throws {
    let watcher = UUID()
    var state = try review(watcher)
    #expect(throws: EnrollmentBlocker.staleWatcher) { try state.observeRemoval(instance: 1, watcher: UUID()) }
    #expect(throws: EnrollmentBlocker.invalidated) { try state.observeRemoval(instance: 1, watcher: watcher) }
}

@Test func powerOrSessionBoundaryAndSecondRemovalInvalidateReview() throws {
    let watcher = UUID()
    var state = try review(watcher)
    try state.observeRemoval(instance: 1, watcher: watcher)
    try state.observeReconnect(inventory: [device(2)], watcher: watcher)
    #expect(throws: EnrollmentBlocker.invalidated) { try state.observeRemoval(instance: 2, watcher: watcher) }
    #expect(throws: EnrollmentBlocker.invalidated) { try state.enrollment(id: UUID(), inventory: [device(2)], watcher: watcher, disarmed: true) }
    var other = try review(watcher)
    other.invalidate()
    #expect(throws: EnrollmentBlocker.invalidated) { try other.observeRemoval(instance: 1, watcher: watcher) }
}
