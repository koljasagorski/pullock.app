import Foundation

public enum ValidationError: String, Error, Sendable {
    case invalidSerial, invalidVendor, invalidProducts, invalidRevision, invalidLease
}

public struct Enrollment: Equatable, Codable, Sendable {
    public let id: UUID
    public let vendorID: UInt16
    public let acceptedProductIDs: Set<UInt16>
    /// Sensitive local policy data; never included in StateSnapshot.
    public let serial: String

    public init(id: UUID, vendorID: UInt16, acceptedProductIDs: Set<UInt16>, serial: String) throws {
        self.id = id
        self.vendorID = vendorID
        self.acceptedProductIDs = acceptedProductIDs
        self.serial = serial
        try validate()
    }

    public func validate() throws {
        guard vendorID != 0 else { throw ValidationError.invalidVendor }
        guard !acceptedProductIDs.isEmpty, acceptedProductIDs.count <= 32,
              !acceptedProductIDs.contains(0) else { throw ValidationError.invalidProducts }
        guard Self.isValidSerial(serial) else { throw ValidationError.invalidSerial }
    }

    public static func isValidSerial(_ serial: String) -> Bool {
        !serial.isEmpty && serial.utf8.count <= 256
            && !serial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !serial.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    public func matches(_ device: DeviceObservation) -> Bool {
        device.vendorID == vendorID && acceptedProductIDs.contains(device.productID)
            && device.serial == serial
    }

    public func claimsIdentity(_ device: DeviceObservation) -> Bool {
        device.vendorID == vendorID && device.serial == serial
    }
}

public struct DeviceObservation: Equatable, Sendable {
    public let instance: UInt64
    public let vendorID: UInt16
    public let productID: UInt16
    public let serial: String?

    public init(instance: UInt64, vendorID: UInt16, productID: UInt16, serial: String?) {
        self.instance = instance
        self.vendorID = vendorID
        self.productID = productID
        self.serial = serial
    }

    public var isValid: Bool {
        instance != 0 && vendorID != 0 && productID != 0
            && (serial.map(Enrollment.isValidSerial) ?? true)
    }
}

public enum ActionMode: String, Codable, Sendable {
    case lock, lockAndShutdown
}

public struct ProtectionPolicy: Equatable, Codable, Sendable {
    public let revision: UInt64
    public let enrollment: Enrollment
    public let mode: ActionMode
    public let shutdownAcknowledged: Bool

    public init(revision: UInt64, enrollment: Enrollment, mode: ActionMode = .lock,
                shutdownAcknowledged: Bool = false) throws {
        self.revision = revision
        self.enrollment = enrollment
        self.mode = mode
        self.shutdownAcknowledged = shutdownAcknowledged
        try validate()
    }

    public func validate() throws {
        guard revision > 0 else { throw ValidationError.invalidRevision }
        try enrollment.validate()
    }
}
