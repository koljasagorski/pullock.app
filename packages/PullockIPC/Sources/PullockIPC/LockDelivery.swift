import Foundation
import PullockCore

/// A separate reverse-call stream, bound to a nonce supplied by the already
/// authenticated agent. Health reply sequences cannot be replayed as actions.
public struct LockDelivery: Equatable, Codable, Sendable {
    public let version: Int
    public let nonce: UUID
    public let boot: UUID
    public let sequence: UInt64
    public let issuedAt: UInt64
    public let validUntil: UInt64
    public let id: ActionID

    public init(nonce: UUID, sequence: UInt64, issuedAt: UInt64, id: ActionID) throws {
        let end = issuedAt.addingReportingOverflow(2_000)
        guard !end.overflow, sequence > 0, id.kind == .lock, id.trigger.arming > 0 else { throw WireError.invalidPayload }
        version = 1; self.nonce = nonce; boot = id.trigger.boot; self.sequence = sequence
        self.issuedAt = issuedAt; validUntil = end.partialValue; self.id = id
    }

    public func validate(nonce: UUID, boot: UUID, after sequence: UInt64, now: UInt64) throws {
        guard version == 1 else { throw WireError.unsupportedVersion }
        guard self.nonce == nonce else { throw WireError.wrongConnection }
        guard self.boot == boot, id.trigger.boot == boot else { throw WireError.wrongBoot }
        guard self.sequence > sequence else { throw WireError.staleSequence }
        guard id.kind == .lock, id.trigger.arming > 0, issuedAt <= now,
              now < validUntil, validUntil > issuedAt, validUntil - issuedAt <= 2_000 else {
            throw WireError.invalidPayload
        }
    }
}

public struct LockDeliveryReply: Equatable, Codable, Sendable {
    public let version: Int
    public let nonce: UUID
    public let sequence: UInt64
    public let result: ActionResult

    public init(delivery: LockDelivery, result: ActionResult) throws {
        guard result.id == delivery.id, result.outcome == .unknown || result.outcome == .failed else {
            throw WireError.invalidPayload
        }
        version = 1; nonce = delivery.nonce; sequence = delivery.sequence; self.result = result
    }

    public func validate(for delivery: LockDelivery) throws {
        guard version == 1, nonce == delivery.nonce, sequence == delivery.sequence,
              result.id == delivery.id, result.outcome == .unknown || result.outcome == .failed else {
            throw WireError.invalidPayload
        }
    }
}

public enum LockDeliveryCodec {
    public static let maximumBytes = 1_024
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumBytes else { throw WireError.tooLarge }
        return data
    }
    public static func decode<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= maximumBytes else { throw WireError.tooLarge }
        let value: T
        do { value = try JSONDecoder().decode(type, from: data) }
        catch { throw WireError.malformed }
        // Every field is nonoptional. Canonical JSON equality rejects extra
        // fields at every depth, including nested action IDs.
        let input = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        let canonical = try JSONSerialization.jsonObject(with: encode(value)) as? NSDictionary
        guard let input, let canonical, input == canonical else { throw WireError.unknownFields }
        return value
    }
}

@objc public protocol PullockLockTransport {
    func deliver(_ packet: NSData, reply: @escaping @Sendable (NSData?) -> Void)
}

public enum PullockLockInterface {
    public static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: PullockLockTransport.self)
        let selector = #selector(PullockLockTransport.deliver(_:reply:))
        let allowed = NSSet(object: NSData.self) as! Set<AnyHashable>
        interface.setClasses(allowed, for: selector, argumentIndex: 0, ofReply: false)
        interface.setClasses(allowed, for: selector, argumentIndex: 0, ofReply: true)
        return interface
    }
}
