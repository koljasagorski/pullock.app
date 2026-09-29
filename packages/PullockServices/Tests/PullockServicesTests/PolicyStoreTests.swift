import Darwin
import Foundation
import PullockCore
@testable import PullockServices
import Testing

private func inDirectory(_ body: (URL, PolicyStore) throws -> Void) throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("pullock-store-\(UUID())")
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: path) }
    try body(path, PolicyStore.testStore(directory: path, owner: geteuid()))
}

private func record(_ revision: UInt64 = 1, owner: UInt32 = 501) throws -> StoredPolicy {
    try StoredPolicy(ownerUID: owner, policy: ProtectionPolicy(revision: revision,
        enrollment: Enrollment(id: UUID(), vendorID: 0x1050, acceptedProductIDs: [0x0407], serial: "SYNTHETIC-ONLY")))
}

@Test func policyRoundTripAndAtomicRevision() throws {
    try inDirectory { path, store in
        #expect(try store.load() == nil)
        let initial = try record()
        try store.save(initial, expectedRevision: nil)
        #expect(try store.load() == initial)
        let updated = try record(2)
        try store.save(updated, expectedRevision: 1)
        #expect(try store.load() == updated)
        let attributes = try FileManager.default.attributesOfItem(atPath: path.appendingPathComponent("policy.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: path.path).sorted() == [".policy.lock", "policy.json"])
    }
}

@Test func staleRevisionAndOwnerSwapDoNotOverwritePolicy() throws {
    try inDirectory { _, store in
        let initial = try record()
        try store.save(initial, expectedRevision: nil)
        #expect(throws: PolicyStoreError.revisionConflict) { try store.save(record(2), expectedRevision: nil) }
        #expect(throws: PolicyStoreError.revisionConflict) { try store.save(record(3), expectedRevision: 1) }
        #expect(throws: PolicyStoreError.ownerConflict) { try store.save(record(2, owner: 502), expectedRevision: 1) }
        #expect(try store.load() == initial)
    }
}

@Test func directoryPermissionsAndOwnerAreCheckedAgain() throws {
    try inDirectory { path, store in
        #expect(throws: PolicyStoreError.unsafeDirectory) {
            try PolicyStore.testStore(directory: path, owner: geteuid() + 1)
        }
        #expect(chmod(path.path, 0o755) == 0)
        #expect(throws: PolicyStoreError.unsafeDirectory) { try store.load() }
    }
}

@Test func symlinkAndHardlinkPoliciesAreRejected() throws {
    try inDirectory { path, store in
        let outside = path.appendingPathComponent("outside.json")
        try Data("untouched".utf8).write(to: outside)
        #expect(chmod(outside.path, 0o600) == 0)
        let file = path.appendingPathComponent("policy.json")
        #expect(symlink(outside.path, file.path) == 0)
        #expect(throws: PolicyStoreError.unsafeFile) { try store.load() }
        #expect(throws: PolicyStoreError.unsafeFile) { try store.save(record(), expectedRevision: nil) }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "untouched")
        #expect(unlink(file.path) == 0)
        #expect(link(outside.path, file.path) == 0)
        #expect(throws: PolicyStoreError.unsafeFile) { try store.load() }
    }
}

@Test func fifoAndSymlinkLockCannotBlockOrRedirectStore() throws {
    try inDirectory { path, store in
        let lock = path.appendingPathComponent(".policy.lock")
        #expect(mkfifo(lock.path, 0o600) == 0)
        #expect(throws: PolicyStoreError.unsafeFile) { try store.load() }
        #expect(unlink(lock.path) == 0)
        #expect(symlink("missing-target", lock.path) == 0)
        #expect(throws: PolicyStoreError.unsafeFile) { try store.load() }
    }
}

@Test func malformedOversizedAndInsecurePolicyFilesAreRejected() throws {
    try inDirectory { path, store in
        let file = path.appendingPathComponent("policy.json")
        try Data("{}".utf8).write(to: file)
        #expect(chmod(file.path, 0o644) == 0)
        #expect(throws: PolicyStoreError.unsafeFile) { try store.load() }
        #expect(chmod(file.path, 0o600) == 0)
        #expect(throws: PolicyStoreError.malformed) { try store.load() }
        try Data(repeating: 65, count: PolicyStore.maximumBytes + 1).write(to: file)
        #expect(throws: PolicyStoreError.tooLarge) { try store.load() }
    }
}

@Test func unknownSchemaAndFieldsCannotBecomePolicy() throws {
    try inDirectory { path, store in
        let encoded = try JSONEncoder().encode(record())
        var data = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        data["schema"] = 2
        let file = path.appendingPathComponent("policy.json")
        try JSONSerialization.data(withJSONObject: data).write(to: file)
        #expect(chmod(file.path, 0o600) == 0)
        #expect(throws: PolicyStoreError.malformed) { try store.load() }
        data["schema"] = 1; data["armAtStartup"] = true
        try JSONSerialization.data(withJSONObject: data).write(to: file)
        #expect(throws: PolicyStoreError.malformed) { try store.load() }
    }
}

@Test func concurrentStoreInstanceHonorsAdvisoryLock() throws {
    try inDirectory { path, store in
        _ = try store.load()
        let fd = open(path.appendingPathComponent(".policy.lock").path, O_RDWR | O_CLOEXEC)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        defer { flock(fd, LOCK_UN) }
        #expect(throws: PolicyStoreError.busy) { try store.save(record(), expectedRevision: nil) }
    }
}

@Test func extendedACLsCannotBypassPrivateModeBits() throws {
    try inDirectory { path, store in
        try store.save(record(), expectedRevision: nil)
        let file = path.appendingPathComponent("policy.json")
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow read", file.path]
        try chmod.run(); chmod.waitUntilExit()
        #expect(chmod.terminationStatus == 0)
        #expect(throws: PolicyStoreError.unsafeFile) { try store.load() }
    }
    try inDirectory { path, store in
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow search", path.path]
        try chmod.run(); chmod.waitUntilExit()
        #expect(chmod.terminationStatus == 0)
        #expect(throws: PolicyStoreError.unsafeDirectory) { try store.load() }
    }
}

@Test func currentConnectionSelectionIsNeverPersisted() throws {
    try inDirectory { _, store in
        let connection = try ConnectionIdentity(bootID: UUID(), watcher: 1, power: 0, instance: 42)
        let enrollment = try Enrollment(id: UUID(), vendorID: 0x1234, productID: 0x4321, connection: connection)
        let policy = try ProtectionPolicy(revision: 1, enrollment: enrollment)
        #expect(throws: PolicyStoreError.malformed) { try store.save(StoredPolicy(ownerUID: 501, policy: policy), expectedRevision: nil) }
        #expect(try store.load() == nil)
    }
}
