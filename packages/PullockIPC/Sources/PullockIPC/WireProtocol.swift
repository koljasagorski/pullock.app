import Foundation
import PullockCore

public enum ProcessRole: String, Codable, CaseIterable, Sendable { case app, sessionAgent, daemon }

public enum WirePayload: Equatable, Codable, Sendable {
    case hello(role: ProcessRole)
    case getHealth
    case configure(policy: ProtectionPolicy, expectedRevision: UInt64?)
    case arm(expectedRevision: UInt64)
    case disarm(expectedArming: UInt64)
    case resetTrigger(id: TriggerID)
    case sessionHeartbeat(generation: UInt64, progress: UInt64)
    case lockResult(result: ActionResult)
    case performLock(id: ActionID)
    case snapshot(state: StateSnapshot)
}

public struct WireEnvelope: Equatable, Codable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public let connectionID: UUID
    public let bootID: UUID
    public let sequence: UInt64
    public let payload: WirePayload

    public init(version: Int = currentVersion, connectionID: UUID, bootID: UUID,
                sequence: UInt64, payload: WirePayload) {
        self.version = version; self.connectionID = connectionID; self.bootID = bootID
        self.sequence = sequence; self.payload = payload
    }
}

public enum WireError: String, Error, Sendable {
    case tooLarge, malformed, unknownFields, unsupportedVersion, wrongConnection, wrongBoot
    case staleSequence, handshakeRequired, duplicateHandshake, roleViolation, invalidPayload, staleSnapshot
}

public enum WireCodec {
    public static let maximumBytes = 16_384

    public static func encode(_ envelope: WireEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        guard data.count <= maximumBytes else { throw WireError.tooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> WireEnvelope {
        guard data.count <= maximumBytes else { throw WireError.tooLarge }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) } catch { throw WireError.malformed }
        guard let root = object as? [String: Any],
              Set(root.keys) == ["version", "connectionID", "bootID", "sequence", "payload"],
              let payload = root["payload"] as? [String: Any], payload.count == 1,
              let entry = payload.first, let fields = entry.value as? [String: Any] else {
            throw WireError.unknownFields
        }
        let shapes: [String: Set<String>] = [
            "hello": ["role"], "getHealth": [], "configure": ["policy", "expectedRevision"],
            "arm": ["expectedRevision"], "disarm": ["expectedArming"], "resetTrigger": ["id"],
            "sessionHeartbeat": ["generation", "progress"], "lockResult": ["result"],
            "performLock": ["id"], "snapshot": ["state"],
        ]
        guard let allowed = shapes[entry.key], Set(fields.keys).isSubset(of: allowed) else {
            throw WireError.unknownFields
        }
        if entry.key == "configure" {
            guard let policy = fields["policy"] as? [String: Any],
                  Set(policy.keys) == ["revision", "enrollment", "mode", "shutdownAcknowledged"],
                  let enrollment = policy["enrollment"] as? [String: Any],
                  Set(enrollment.keys) == ["id", "vendorID", "acceptedProductIDs", "serial"]
                    || Set(enrollment.keys) == ["id", "vendorID", "acceptedProductIDs", "serial", "connection"] else {
                throw WireError.unknownFields
            }
        }
        let envelope: WireEnvelope
        do { envelope = try JSONDecoder().decode(WireEnvelope.self, from: data) } catch { throw WireError.malformed }
        guard envelope.version == WireEnvelope.currentVersion else { throw WireError.unsupportedVersion }
        let canonical = try JSONSerialization.jsonObject(with: encode(envelope))
        try rejectUnknownFields(object, canonical: canonical, path: [])
        return envelope
    }

    private static func rejectUnknownFields(_ input: Any, canonical: Any, path: [String]) throws {
        if let input = input as? [String: Any], let canonical = canonical as? [String: Any] {
            for (key, value) in input {
                if let known = canonical[key] {
                    try rejectUnknownFields(value, canonical: known, path: path + [key])
                } else {
                    let nullable: Set<String>
                    switch path {
                    case ["payload", "configure"]: nullable = ["expectedRevision"]
                    case ["payload", "snapshot", "state"]:
                        nullable = ["policyRevision", "trigger", "lockOutcome", "shutdownOutcome"]
                    default: nullable = []
                    }
                    guard nullable.contains(key), value is NSNull else { throw WireError.unknownFields }
                }
            }
        } else if let input = input as? [Any], let canonical = canonical as? [Any] {
            guard input.count == canonical.count else { throw WireError.invalidPayload }
            for (value, known) in zip(input, canonical) {
                try rejectUnknownFields(value, canonical: known, path: path)
            }
        }
    }
}

/// Protocol validation only. M4 must first authenticate OS code signing, role,
/// effective UID and session. A hello or this initializer is NOT authentication.
/// Construct a fresh validator after every authenticated connection replacement.
public struct WireSession: Sendable {
    public let localRole: ProcessRole
    public let remoteRole: ProcessRole
    public let connectionID: UUID
    public let bootID: UUID
    public private(set) var established = false
    private var lastSequence: UInt64 = 0

    public init(localRole: ProcessRole, remoteRole: ProcessRole, connectionID: UUID, bootID: UUID) {
        self.localRole = localRole; self.remoteRole = remoteRole
        self.connectionID = connectionID; self.bootID = bootID
    }

    public mutating func receive(_ data: Data, now: UInt64) throws -> WirePayload {
        let envelope = try WireCodec.decode(data)
        guard envelope.connectionID == connectionID else { throw WireError.wrongConnection }
        guard envelope.bootID == bootID else { throw WireError.wrongBoot }
        guard envelope.sequence > lastSequence else { throw WireError.staleSequence }
        if case let .hello(role) = envelope.payload {
            guard !established else { throw WireError.duplicateHandshake }
            guard role == remoteRole, role != localRole,
                  localRole == .daemon || remoteRole == .daemon else { throw WireError.roleViolation }
            established = true
        } else {
            guard established else { throw WireError.handshakeRequired }
            guard authorized(envelope.payload) else { throw WireError.roleViolation }
            try validate(envelope.payload, now: now)
        }
        lastSequence = envelope.sequence
        return envelope.payload
    }

    private func authorized(_ payload: WirePayload) -> Bool {
        switch payload {
        case .hello: false
        case .getHealth: localRole == .daemon && (remoteRole == .app || remoteRole == .sessionAgent)
        case .configure, .arm, .disarm, .resetTrigger: localRole == .daemon && remoteRole == .app
        case .sessionHeartbeat, .lockResult: localRole == .daemon && remoteRole == .sessionAgent
        case .performLock: localRole == .sessionAgent && remoteRole == .daemon
        case .snapshot: remoteRole == .daemon && (localRole == .app || localRole == .sessionAgent)
        }
    }

    private func validate(_ payload: WirePayload, now: UInt64) throws {
        switch payload {
        case let .configure(policy, _):
            do { try policy.validate() } catch { throw WireError.invalidPayload }
        case let .arm(revision):
            guard revision > 0 else { throw WireError.invalidPayload }
        case let .sessionHeartbeat(generation, progress):
            guard generation > 0, progress > 0 else { throw WireError.invalidPayload }
        case let .performLock(id):
            guard id.kind == .lock, id.trigger.boot == bootID, id.trigger.arming > 0 else {
                throw WireError.invalidPayload
            }
        case let .lockResult(result):
            guard result.id.kind == .lock, result.id.trigger.boot == bootID,
                  result.id.trigger.arming > 0 else { throw WireError.invalidPayload }
        case let .resetTrigger(id):
            guard id.boot == bootID, id.arming > 0 else { throw WireError.invalidPayload }
        case let .snapshot(state):
            guard state.bootID == bootID, state.generatedAt <= now, now < state.validUntil,
                  state.validUntil - state.generatedAt <= 60_000 else { throw WireError.staleSnapshot }
            guard state.status != .armed || state.hasArmedInvariants else { throw WireError.invalidPayload }
            if state.profile == .live, state.lockOutcome == .simulated || state.shutdownOutcome == .simulated {
                throw WireError.invalidPayload
            }
        case .hello, .getHealth, .disarm: break
        }
    }
}
