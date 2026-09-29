import Foundation

public enum ConnectionSelectionError: String, Error, Sendable {
    case missing, invalidInventory, expired, wrongWatcher
}

/// A choice of one currently attached USB registry instance. No serial number,
/// content read, reconnect recognition or persistence. A host invalidates this
/// value on sleep/session boundaries and watcher failure, even if the same
/// registry entry remains visible afterwards.
public struct ConnectionSelection: Equatable, Sendable {
    public let watcherID: UUID
    public let instance: UInt64
    public let vendorID: UInt16
    public let productID: UInt16
    public private(set) var expired = false

    public init(instance: UInt64, inventory: [USBDevice], watcherID: UUID) throws {
        try Self.validateInventory(inventory)
        guard let device = inventory.first(where: { $0.instance == instance }) else {
            throw ConnectionSelectionError.missing
        }
        self.watcherID = watcherID; self.instance = instance
        vendorID = device.vendorID; productID = device.productID
    }

    public mutating func reconcile(_ inventory: [USBDevice], watcherID: UUID) throws {
        do {
            guard !expired else { throw ConnectionSelectionError.expired }
            guard self.watcherID == watcherID else { throw ConnectionSelectionError.wrongWatcher }
            try Self.validateInventory(inventory)
            guard inventory.contains(where: {
                $0.instance == instance && $0.vendorID == vendorID && $0.productID == productID
            }) else { throw ConnectionSelectionError.missing }
        } catch { expired = true; throw error }
    }

    /// Returns true once, only for the selected connection's disappearance.
    public mutating func removed(_ instance: UInt64) -> Bool {
        guard !expired, instance == self.instance else { return false }
        expired = true
        return true
    }

    public mutating func invalidate() { expired = true }

    private static func validateInventory(_ inventory: [USBDevice]) throws {
        guard inventory.count <= 128, Set(inventory.map(\.instance)).count == inventory.count,
              inventory.allSatisfy({ $0.instance > 0 && $0.vendorID > 0 && $0.productID > 0 }) else {
            throw ConnectionSelectionError.invalidInventory
        }
    }
}
