import Foundation
import PullockCore

public enum EnrollmentBlocker: String, Error, Codable, Sendable {
    case notDisarmed, candidateMissing, missingSerial, invalidSerial, conflictingSerial
    case duplicateIdentity, unqualifiedProfile, reconnectRequired, wrongInstance, staleWatcher
    case invalidInventory, invalidated
}

/// Supplied only from the daemon's reviewed compatibility data, never a client
/// claim. No hardware profile is qualified in the current release.
public struct QualifiedUSBProfile: Sendable {
    public let vendorID: UInt16
    public let productIDs: Set<UInt16>
    public init(vendorID: UInt16, productIDs: Set<UInt16>) {
        self.vendorID = vendorID; self.productIDs = productIDs
    }
}

/// In-memory, disarmed enrollment investigation. No policy is persisted here.
/// A matching reconnect is evidence, not full model/topology qualification.
public struct EnrollmentReview: Sendable {
    private let watcher: UUID
    private let original: USBDevice
    private let profile: QualifiedUSBProfile
    private var removed = false
    private var reconnected: USBDevice?
    private var invalidated = false

    public init(candidate: UInt64, inventory: [USBDevice], watcher: UUID,
                disarmed: Bool, qualifiedProfiles: [QualifiedUSBProfile]) throws {
        guard disarmed else { throw EnrollmentBlocker.notDisarmed }
        try Self.validate(inventory)
        guard let device = inventory.first(where: { $0.instance == candidate }) else {
            throw EnrollmentBlocker.candidateMissing
        }
        let serial = try Self.serial(of: device)
        guard inventory.filter({ $0.vendorID == device.vendorID && $0.observation.serial == serial }).count == 1 else {
            throw EnrollmentBlocker.duplicateIdentity
        }
        guard let profile = qualifiedProfiles.first(where: {
            $0.vendorID == device.vendorID && $0.productIDs.contains(device.productID)
                && $0.productIDs.count <= 32 && !$0.productIDs.contains(0)
        }) else { throw EnrollmentBlocker.unqualifiedProfile }
        self.watcher = watcher; self.original = device; self.profile = profile
    }

    public mutating func observeRemoval(instance: UInt64, watcher: UUID) throws {
        try check(watcher)
        if instance == reconnected?.instance { invalidate(); throw EnrollmentBlocker.invalidated }
        guard instance == original.instance else { throw EnrollmentBlocker.wrongInstance }
        removed = true
        reconnected = nil
    }

    public mutating func observeReconnect(inventory: [USBDevice], watcher: UUID) throws {
        reconnected = nil
        try check(watcher)
        try Self.validate(inventory)
        guard removed else { throw EnrollmentBlocker.reconnectRequired }
        let serial = try Self.serial(of: original)
        let matches = inventory.filter { $0.vendorID == original.vendorID && $0.observation.serial == serial }
        guard matches.count <= 1 else { reconnected = nil; throw EnrollmentBlocker.duplicateIdentity }
        guard let device = matches.first, device.instance != original.instance else {
            reconnected = nil; throw EnrollmentBlocker.reconnectRequired
        }
        guard profile.productIDs.contains(device.productID) else {
            reconnected = nil; throw EnrollmentBlocker.unqualifiedProfile
        }
        reconnected = device
    }

    public func enrollment(id: UUID, inventory: [USBDevice], watcher: UUID, disarmed: Bool) throws -> Enrollment {
        guard disarmed else { throw EnrollmentBlocker.notDisarmed }
        guard !invalidated else { throw EnrollmentBlocker.invalidated }
        guard watcher == self.watcher else { throw EnrollmentBlocker.staleWatcher }
        try Self.validate(inventory)
        guard let device = reconnected, inventory.contains(device) else { throw EnrollmentBlocker.reconnectRequired }
        let serial = try Self.serial(of: device)
        guard inventory.filter({ $0.vendorID == device.vendorID && $0.observation.serial == serial }).count == 1 else {
            throw EnrollmentBlocker.duplicateIdentity
        }
        return try Enrollment(id: id, vendorID: device.vendorID, acceptedProductIDs: profile.productIDs, serial: serial)
    }

    /// The owner must invalidate on sleep, session/arming changes, watcher error
    /// or restart. A review cannot resume across these observation boundaries.
    public mutating func invalidate() {
        invalidated = true
        reconnected = nil
    }

    private mutating func check(_ watcher: UUID) throws {
        guard !invalidated else { throw EnrollmentBlocker.invalidated }
        guard watcher == self.watcher else { invalidate(); throw EnrollmentBlocker.staleWatcher }
    }

    private static func validate(_ inventory: [USBDevice]) throws {
        guard inventory.count <= 128,
              Set(inventory.map(\.instance)).count == inventory.count,
              inventory.allSatisfy({ $0.observation.isValid }) else {
            throw EnrollmentBlocker.invalidInventory
        }
    }

    public static func blocker(candidate: UInt64, inventory: [USBDevice], qualifiedProfiles: [QualifiedUSBProfile]) -> EnrollmentBlocker? {
        do {
            _ = try Self(candidate: candidate, inventory: inventory, watcher: UUID(), disarmed: true,
                         qualifiedProfiles: qualifiedProfiles)
            return .reconnectRequired
        } catch let error as EnrollmentBlocker { return error }
        catch { return .invalidSerial }
    }

    private static func serial(of device: USBDevice) throws -> String {
        switch device.serial {
        case .missing: throw EnrollmentBlocker.missingSerial
        case .invalid: throw EnrollmentBlocker.invalidSerial
        case .conflicting: throw EnrollmentBlocker.conflictingSerial
        case let .presentUnqualified(value, _):
            guard Enrollment.isValidSerial(value) else { throw EnrollmentBlocker.invalidSerial }
            return value
        }
    }
}
