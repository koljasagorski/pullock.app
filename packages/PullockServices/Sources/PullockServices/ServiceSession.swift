import Foundation
import PullockCore
import PullockIPC

public enum ServiceSessionError: String, Error, Sendable { case closed, wrongPhase, operationUnavailable }

/// Serialized protocol state for one authenticated connection. Signature/OS
/// admission must precede this type. It cannot promote a role from wire input.
public struct ServiceSession: Sendable {
    public let id: UUID
    public let bootID: UUID
    public let role: ProcessRole
    public private(set) var closed = false
    public var established: Bool { bootstrapped && wire.established && !closed }
    private var wire: WireSession
    private var bootstrapped = false
    private var sequence: UInt64 = 0
    private var budget = ConnectionBudget()

    public init(bootID: UUID, role: ProcessRole) throws {
        guard role != .daemon else { throw PeerPolicyError.invalidRole }
        id = UUID(); self.bootID = bootID; self.role = role
        wire = WireSession(localRole: .daemon, remoteRole: role, connectionID: id, bootID: bootID)
    }

    public mutating func receive(_ data: Data, now: UInt64, snapshot: StateSnapshot,
                                command: ((WirePayload) throws -> WirePayload)? = nil) throws -> Data {
        guard !closed else { throw ServiceSessionError.closed }
        do {
            let ticket = try budget.begin(byteCount: data.count, now: now)
            let reply: Data
            if !bootstrapped {
                let request = try BootstrapCodec.request(data)
                bootstrapped = true
                reply = try BootstrapCodec.encode(BootstrapReply(nonce: request.nonce, connectionID: id, bootID: bootID))
            } else {
                let payload = try wire.receive(data, now: now)
                let response: WirePayload
                switch payload {
                case .hello: response = .hello(role: .daemon)
                case .getHealth:
                    guard snapshot.bootID == bootID, snapshot.generatedAt <= now, now < snapshot.validUntil else {
                        throw WireError.staleSnapshot
                    }
                    response = try command?(payload) ?? .snapshot(state: snapshot)
                default:
                    guard let command else { throw ServiceSessionError.operationUnavailable }
                    response = try command(payload)
                }
                sequence += 1
                reply = try WireCodec.encode(WireEnvelope(connectionID: id, bootID: bootID,
                                                         sequence: sequence, payload: response))
            }
            try budget.finish(ticket, now: now)
            return reply
        } catch {
            invalidate()
            throw error
        }
    }

    public mutating func invalidate() { closed = true; budget.invalidate() }
}
