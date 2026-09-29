import Foundation
import Testing
@testable import ProbeSupport

@Test func missingOrMalformedSerialNeverQualifies() {
    #expect(SerialEvidence.read([:], keys: ["serial"]) == .missing)
    for value: Any in [NSNumber(value: 12), "", " \t", "bad\nserial", String(repeating: "x", count: 257)] {
        #expect(SerialEvidence.read(["serial": value], keys: ["serial"]) == .invalid)
    }
}

@Test func exactSerialAndConflictingAliases() {
    #expect(SerialEvidence.read(["a": "Abc", "b": "abc"], keys: ["a", "b"]) == .conflicting)
    #expect(SerialEvidence.read(["a": "123", "b": "123 "], keys: ["a", "b"]) == .conflicting)
    #expect(SerialEvidence.read(["a": "123", "b": "123"], keys: ["a", "b"]) ==
        .presentUnqualified(value: "123", sources: ["a", "b"]))
}

@Test func numericDescriptorsAreStrict() {
    #expect(usbIdentifier(NSNumber(value: 0x1050)) == 0x1050)
    #expect(usbIdentifier(NSNumber(value: 65535)) == 65535)
    for value: Any in [true, "4176", NSNumber(value: -1), NSNumber(value: 65536),
                       NSNumber(value: 4176.5), NSNumber(value: 4176.0), NSNumber(value: UInt64.max)] {
        #expect(usbIdentifier(value) == nil)
    }
    #expect(usbIdentifier(nil) == nil)
}

@Test func reportsDoNotRevealOrGloballyCorrelateSerials() throws {
    let first = ReportRedactor()
    let second = ReportRedactor()
    let evidence = SerialEvidence.presentUnqualified(value: "TEST-SECRET-1234", sources: ["serial"])
    let fields = first.fields(for: evidence)
    #expect(fields == first.fields(for: evidence))
    #expect(fields["serial_token"] != second.fields(for: evidence)["serial_token"])
    #expect(fields["enrollment"] == "not_qualified")
    #expect(!String(decoding: try JSONEncoder().encode(fields), as: UTF8.self).contains("TEST-SECRET"))
    #expect(first.token(domain: "serial", value: "1") != first.token(domain: "instance", value: "1"))
}

@Test func mockRequiresPresenceAndDoesNotReplayRemoval() {
    var probe = MockRemovalProbe()
    let startupRemoval = probe.removed(1)
    #expect(!startupRemoval)
    probe.observed(1)
    probe.observed(1)
    let otherRemoval = probe.removed(2)
    let firstRemoval = probe.removed(1)
    let duplicateRemoval = probe.removed(1)
    #expect(!otherRemoval)
    #expect(firstRemoval)
    #expect(!duplicateRemoval)
    #expect(probe.simulatedLocks == 1)
}

@Test func sleepAndSessionChangesInvalidatePresence() {
    var probe = MockRemovalProbe()
    probe.observed(1)
    probe.invalidatePresence()
    probe.observed(2)
    let oldRemoval = probe.removed(1)
    let sleepingRemoval = probe.removed(2)
    #expect(!oldRemoval)
    #expect(!sleepingRemoval)
    probe.beginFreshObservation()
    let staleRemoval = probe.removed(1)
    #expect(!staleRemoval)
    probe.observed(3)
    let freshRemoval = probe.removed(3)
    #expect(freshRemoval)
    #expect(probe.powerEpoch == 1)
}

@Test func oppositeCallbackOrdersAreNotEquivalentEvidence() {
    var terminationFirst = MockRemovalProbe()
    terminationFirst.observed(1)
    let earlyRemoval = terminationFirst.removed(1)
    #expect(earlyRemoval)
    terminationFirst.invalidatePresence()
    var sleepFirst = MockRemovalProbe()
    sleepFirst.observed(1)
    sleepFirst.invalidatePresence()
    let lateRemoval = sleepFirst.removed(1)
    #expect(!lateRemoval)
    // Demonstrates the unresolved cross-source ordering risk, not a solution.
    #expect(terminationFirst.simulatedLocks != sleepFirst.simulatedLocks)
}

@Test func cliCannotEnableSystemActions() throws {
    #expect(try parseCommand([]) == .inspect)
    #expect(try parseCommand(["watch"]) == .watch(seconds: 30))
    #expect(try parseCommand(["watch", "--seconds", "1"]) == .watch(seconds: 1))
    for arguments in [["lock"], ["shutdown"], ["inspect", "--real"], ["watch", "--seconds", "0"],
                      ["watch", "--seconds", "3601"], ["watch", "--seconds", "nan"]] {
        #expect(throws: ProbeUsageError.self) { try parseCommand(arguments) }
    }
}
