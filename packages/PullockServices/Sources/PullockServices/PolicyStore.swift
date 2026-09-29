import Darwin
import Foundation
import PullockCore

public enum PolicyStoreError: String, Error, Sendable {
    case permission, unsafeDirectory, unsafeFile, unavailable, busy, malformed, tooLarge
    case revisionConflict, ownerConflict, ioFailure
}

public struct StoredPolicy: Codable, Equatable, Sendable {
    public let schema: Int
    public let ownerUID: UInt32
    public let policy: ProtectionPolicy

    public init(ownerUID: UInt32, policy: ProtectionPolicy) throws {
        schema = 1; self.ownerUID = ownerUID; self.policy = policy
        try validate()
    }

    public func validate() throws {
        guard schema == 1, ownerUID != 0, ownerUID != UInt32.max else { throw PolicyStoreError.malformed }
        try policy.validate()
    }
}

/// Descriptor-relative storage. Paths never come from an IPC client. Each
/// operation opens and locks a separate lock-file description, including across
/// instances/processes. No presence, arming epoch or trigger is persisted.
public final class PolicyStore: @unchecked Sendable {
    public static let maximumBytes = 32_768
    private let directory: Int32
    private let owner: UInt32
    private let fileName = "policy.json"

    private init(directory: Int32, owner: UInt32) { self.directory = directory; self.owner = owner }
    deinit { close(directory) }

    public static func production() throws -> PolicyStore {
        guard geteuid() == 0 else { throw PolicyStoreError.permission }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw PolicyStoreError.unavailable }
        defer { close(parent) }
        for component in ["Library", "Application Support"] {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw PolicyStoreError.unsafeDirectory }
            do { try checkDirectory(next, owner: 0, privateDirectory: false) }
            catch { close(next); throw error }
            close(parent); parent = next
        }
        if mkdirat(parent, "Pullock", 0o700) != 0, errno != EEXIST { throw PolicyStoreError.ioFailure }
        let fd = openat(parent, "Pullock", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PolicyStoreError.unsafeDirectory }
        do { try checkDirectory(fd, owner: 0, privateDirectory: true) }
        catch { close(fd); throw error }
        return PolicyStore(directory: fd, owner: 0)
    }

    // Internal test seam: accessible only via @testable, never a runtime flag or
    // endpoint argument. Production always walks the fixed root-owned path.
    static func testStore(directory path: URL, owner: UInt32) throws -> PolicyStore {
        let fd = open(path.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PolicyStoreError.unsafeDirectory }
        do { try checkDirectory(fd, owner: owner, privateDirectory: true) }
        catch { close(fd); throw error }
        return PolicyStore(directory: fd, owner: owner)
    }

    public func load() throws -> StoredPolicy? {
        try locked { try readPolicy() }
    }

    public func save(_ record: StoredPolicy, expectedRevision: UInt64?) throws {
        try record.validate()
        // A connection selection must never survive daemon restart. The old
        // serial-policy format remains readable; ephemeral choices stay in RAM.
        guard record.policy.enrollment.connection == nil else { throw PolicyStoreError.malformed }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard data.count <= Self.maximumBytes else { throw PolicyStoreError.tooLarge }
        try locked {
            let previous = try readPolicy()
            guard previous?.policy.revision == expectedRevision,
                  (previous?.policy.revision ?? 0) < UInt64.max,
                  record.policy.revision == (previous?.policy.revision ?? 0) + 1 else {
                throw PolicyStoreError.revisionConflict
            }
            if let previous, previous.ownerUID != record.ownerUID { throw PolicyStoreError.ownerConflict }
            let temporary = ".policy-\(UUID().uuidString).tmp"
            let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw PolicyStoreError.ioFailure }
            defer { close(fd); unlinkat(directory, temporary, 0) }
            try checkFile(fd)
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { throw PolicyStoreError.malformed }
                var offset = 0
                while offset < bytes.count {
                    let written = write(fd, base.advanced(by: offset), bytes.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw PolicyStoreError.ioFailure }
                    offset += written
                }
            }
            guard fsync(fd) == 0 else { throw PolicyStoreError.ioFailure }
            guard renameat(directory, temporary, directory, fileName) == 0 else { throw PolicyStoreError.ioFailure }
            // A directory-sync error makes commit durability uncertain; report
            // failure. Caller reloads before retrying a revision transaction.
            guard fsync(directory) == 0 else { throw PolicyStoreError.ioFailure }
        }
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try Self.checkDirectory(directory, owner: owner, privateDirectory: true)
        let fd = openat(directory, ".policy.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PolicyStoreError.unsafeFile }
        defer { close(fd) }
        try checkFile(fd)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw PolicyStoreError.busy }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func readPolicy() throws -> StoredPolicy? {
        let fd = openat(directory, fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw PolicyStoreError.unsafeFile
        }
        defer { close(fd) }
        try checkFile(fd)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw PolicyStoreError.ioFailure }
            if count == 0 { break }
            guard data.count + count <= Self.maximumBytes else { throw PolicyStoreError.tooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
        let record: StoredPolicy
        do {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(root.keys) == ["schema", "ownerUID", "policy"],
                  let policy = root["policy"] as? [String: Any],
                  Set(policy.keys) == ["revision", "enrollment", "mode", "shutdownAcknowledged"],
                  let enrollment = policy["enrollment"] as? [String: Any],
                  Set(enrollment.keys) == ["id", "vendorID", "acceptedProductIDs", "serial"] else {
                throw PolicyStoreError.malformed
            }
            record = try JSONDecoder().decode(StoredPolicy.self, from: data)
            try record.validate()
        } catch { throw PolicyStoreError.malformed }
        return record
    }

    private static func checkDirectory(_ fd: Int32, owner: UInt32, privateDirectory: Bool) throws {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == owner, metadata.st_mode & 0o022 == 0,
              !privateDirectory || metadata.st_mode & 0o777 == 0o700 else {
            throw PolicyStoreError.unsafeDirectory
        }
        guard try hasNoACL(fd) else { throw PolicyStoreError.unsafeDirectory }
    }

    private func checkFile(_ fd: Int32) throws {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == owner, metadata.st_mode & 0o777 == 0o600,
              metadata.st_nlink == 1 else { throw PolicyStoreError.unsafeFile }
        guard metadata.st_size <= Self.maximumBytes else { throw PolicyStoreError.tooLarge }
        guard try Self.hasNoACL(fd) else { throw PolicyStoreError.unsafeFile }
    }

    private static func hasNoACL(_ fd: Int32) throws -> Bool {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return true } // No extended ACL on this verified descriptor.
            throw PolicyStoreError.ioFailure
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { throw PolicyStoreError.ioFailure }
        var entry: acl_entry_t?
        let result = acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry)
        // Darwin returns 0 for an entry; a validated empty ACL has no first
        // entry (EINVAL; some implementations use ENOENT).
        if result == 0 { return false }
        guard errno == EINVAL || errno == ENOENT else { throw PolicyStoreError.ioFailure }
        return true
    }
}
