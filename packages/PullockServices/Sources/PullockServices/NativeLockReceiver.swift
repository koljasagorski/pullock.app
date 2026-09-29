import Foundation
import PullockCore
import PullockIPC
import Synchronization

public enum LockTransportError: String, Error, Sendable {
    case unavailable, busy, unauthorized, expired, invalidReply, transport, timeout
}

/// One receiver and one executor live for the session-agent lifetime. A closed
/// connection cannot leave actions queued for a replacement connection. At most
/// one main-actor work item is admitted, including across reconnect attempts.
public final class NativeLockReceiver: NSObject, PullockLockTransport, @unchecked Sendable {
    private struct State {
        var token: UUID?
        var peer: LockReceiverPeer?
        var nonce: UUID?
        var boot: UUID?
        var sequence: UInt64 = 0
        var pending = false
    }
    private let state = Mutex(State())
    private let executor: LockActionExecutor

    public init(executor: LockActionExecutor) { self.executor = executor }
    var hasPendingDelivery: Bool { state.withLock { $0.pending } }

    func attach(_ connection: NSXPCConnection, expectedUID: UInt32) throws -> UUID {
        try state.withLock { state in
            guard state.token == nil, !state.pending else { throw LockTransportError.busy }
            let token = UUID()
            state.token = token
            state.peer = LockReceiverPeer(connection, expectedUID: expectedUID)
            return token
        }
    }

    @MainActor func bind(token: UUID, nonce: UUID, boot: UUID) throws {
        try state.withLock { state in
            guard state.token == token, state.nonce == nil, !state.pending else { throw LockTransportError.unavailable }
            try executor.bind(boot: boot)
            state.nonce = nonce; state.boot = boot; state.sequence = 0
        }
    }

    func detach(token: UUID) {
        state.withLock { state in
            guard state.token == token else { return }
            state.token = nil; state.peer = nil; state.nonce = nil; state.boot = nil
            // Do not clear pending: the previous queued item still occupies
            // the single slot until it is dequeued and observes cancellation.
        }
    }

    public func deliver(_ packet: NSData, reply: @escaping @Sendable (NSData?) -> Void) {
        do {
            // Credential/current-connection checks happen on the NSXPC callback
            // queue, before hopping to the action executor's main actor.
            let (token, delivery) = try state.withLock { state -> (UUID, LockDelivery) in
                guard let token = state.token, let peer = state.peer, peer.isCurrent,
                      peer.authorized, let nonce = state.nonce, let boot = state.boot else {
                    throw LockTransportError.unauthorized
                }
                guard !state.pending else { throw LockTransportError.busy }
                guard packet.length <= LockDeliveryCodec.maximumBytes else { throw WireError.tooLarge }
                let delivery = try LockDeliveryCodec.decode(LockDelivery.self,
                    from: Data(bytes: packet.bytes, count: packet.length))
                try delivery.validate(nonce: nonce, boot: boot, after: state.sequence, now: MonotonicTime.milliseconds)
                state.sequence = delivery.sequence; state.pending = true
                return (token, delivery)
            }
            Task { @MainActor [self] in
                let response: Data?
                do {
                    let result = try state.withLock { state in
                        guard state.token == token, state.peer?.authorized == true,
                              state.nonce == delivery.nonce, state.boot == delivery.boot else {
                            throw LockTransportError.unauthorized
                        }
                        try delivery.validate(nonce: delivery.nonce, boot: delivery.boot,
                            after: delivery.sequence - 1, now: MonotonicTime.milliseconds)
                        // Admission and the synchronous operation are atomic
                        // relative to detach. Already-started OS work cannot
                        // be preempted by later connection invalidation.
                        return try executor.execute(delivery.id)
                    }
                    response = try LockDeliveryCodec.encode(LockDeliveryReply(delivery: delivery, result: result))
                } catch { response = nil }
                state.withLock { $0.pending = false }
                reply(response.map { $0 as NSData })
            }
        } catch { reply(nil) }
    }
}

/// Weak ownership prevents NSXPCConnection -> exported object -> connection
/// cycles. Configuration stays with the client before activation.
private final class LockReceiverPeer: @unchecked Sendable {
    private weak var connection: NSXPCConnection?
    private let expectedUID: UInt32
    init(_ connection: NSXPCConnection, expectedUID: UInt32) {
        self.connection = connection; self.expectedUID = expectedUID
    }
    var isCurrent: Bool { guard let connection else { return false }; return NSXPCConnection.current() === connection }
    var authorized: Bool { connection?.effectiveUserIdentifier == expectedUID }
}
