import Foundation
import PullockCore
import PullockIPC
import Synchronization

public typealias PeerOwnerProvider = @Sendable (UInt32, Int32) throws -> OwnerSessionPolicy

/// Created only after synchronous validation of the current XPC call. These
/// credentials come from NSXPCConnection, never a decoded request.
public struct ServicePeer: Sendable {
    public let role: ProcessRole
    public let owner: OwnerSessionPolicy
    init(role: ProcessRole, owner: OwnerSessionPolicy) { self.role = role; self.owner = owner }
}
public typealias ServiceCommandHandler = @Sendable (ServicePeer, WirePayload, UInt64) throws -> WirePayload

/// Authenticated NSXPC transport with a health-only default. A trusted host may
/// supply a role-constrained command handler; no wire command injects USB events.
/// The owner provider belongs to the host, never the client.
public final class NativeHealthListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private struct State {
        var channels: [UUID: HealthChannel] = [:]
        var running = false
        var stopped = false
    }
    private let state = Mutex(State())
    private let listener: NSXPCListener
    private let trust: ServiceTrust
    private let owner: PeerOwnerProvider
    private let snapshot: @Sendable () -> StateSnapshot
    private let boot: UUID
    private let command: ServiceCommandHandler?
    private let timer: DispatchSourceTimer
    public var endpoint: NSXPCListenerEndpoint { listener.endpoint }
    public var connectionCount: Int { state.withLock { $0.channels.count } }

    public init(trust: ServiceTrust, boot: UUID, owner: @escaping PeerOwnerProvider,
                snapshot: @escaping @Sendable () -> StateSnapshot, command: ServiceCommandHandler? = nil) throws {
        guard trust.role != .daemon else { throw PeerPolicyError.invalidRole }
        self.trust = trust; self.boot = boot; self.owner = owner; self.snapshot = snapshot
        self.command = command
        let suffix = trust.role == .app ? "app" : "session-agent"
        let prefix = trust.development ? "app.pullock.daemon.development" : "app.pullock.daemon"
        listener = NSXPCListener(machServiceName: "\(prefix).\(suffix)")
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "app.pullock.connection-deadlines"))
        super.init()
        configure()
    }

    init(testTrust: ServiceTrust, boot: UUID, owner: @escaping PeerOwnerProvider,
         snapshot: @escaping @Sendable () -> StateSnapshot, command: ServiceCommandHandler? = nil) {
        trust = testTrust; self.boot = boot; self.owner = owner; self.snapshot = snapshot
        self.command = command
        listener = NSXPCListener.anonymous()
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "app.pullock.test-deadlines"))
        super.init()
        configure()
    }

    private func configure() {
        listener.delegate = self
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.expire() }
        timer.activate()
    }

    deinit { stop() }

    public func start() {
        state.withLock { state in
            guard !state.running, !state.stopped else { return }
            state.running = true
            listener.activate()
        }
    }

    public func stop() {
        let channels = state.withLock { state -> [HealthChannel] in
            state.stopped = true; state.running = false
            let channels = Array(state.channels.values); state.channels.removeAll()
            return channels
        }
        timer.cancel()
        listener.invalidate()
        for channel in channels { channel.invalidate() }
    }

    /// Only one authenticated agent may own the reverse route. Ambiguity,
    /// expiry or owner loss disables delivery rather than selecting a peer.
    public func lockRouteAvailable(for owner: OwnerSessionPolicy) -> Bool {
        deliveryChannels(for: owner).count == 1
    }

    public func deliverLock(_ request: ActionRequest, owner: OwnerSessionPolicy) async throws -> ActionResult {
        guard trust.role == .sessionAgent, request.profile == .live, request.id.kind == .lock,
              request.id.trigger.boot == boot else { throw LockTransportError.unauthorized }
        let channels = deliveryChannels(for: owner)
        guard channels.count == 1, let channel = channels.first else { throw LockTransportError.unavailable }
        return try await channel.deliver(request.id, to: owner)
    }

    private func deliveryChannels(for owner: OwnerSessionPolicy) -> [HealthChannel] {
        guard trust.role == .sessionAgent, owner.active else { return [] }
        let channels = state.withLock { state in
            state.running && !state.stopped ? Array(state.channels.values) : []
        }
        return channels.filter { $0.isDeliveryRoute(for: owner) }
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        do {
            let current = try owner(connection.effectiveUserIdentifier, connection.auditSessionIdentifier)
            try current.validate(effectiveUID: connection.effectiveUserIdentifier, auditSession: connection.auditSessionIdentifier)
            connection.setCodeSigningRequirement(trust.requirement)
            let id = UUID()
            let channel = try HealthChannel(connection: connection, boot: boot, role: trust.role, owner: owner, snapshot: snapshot, command: command)
            let accepted = state.withLock { state in
                guard state.running, !state.stopped, state.channels.count < 8 else { return false }
                state.channels[id] = channel
                return true
            }
            guard accepted else { return false }
            connection.exportedInterface = PullockXPCInterface.make()
            connection.exportedObject = channel
            if trust.role == .sessionAgent { connection.remoteObjectInterface = PullockLockInterface.make() }
            connection.invalidationHandler = { [weak self] in
                let channel = self?.state.withLock { $0.channels.removeValue(forKey: id) }
                channel?.invalidate()
            }
            connection.interruptionHandler = { [weak channel] in channel?.invalidate() }
            connection.activate()
            return true
        } catch { return false }
    }

    private func expire() {
        let channels = state.withLock { Array($0.channels.values) }
        let now = MonotonicTime.milliseconds
        for channel in channels where channel.expired(at: now) { channel.invalidate() }
    }
}

private final class HealthChannel: NSObject, PullockXPCTransport, @unchecked Sendable {
    private struct State {
        var session: ServiceSession
        var deadline: UInt64
        var connection: IncomingPeer?
        var deliveryOwner: OwnerSessionPolicy?
        var deliverySequence: UInt64 = 0
        var pendingDelivery: UUID?
        var pendingExchange: UUID?
    }
    private let state: Mutex<State>
    private let owner: PeerOwnerProvider
    private let snapshot: @Sendable () -> StateSnapshot
    private let command: ServiceCommandHandler?
    private let role: ProcessRole

    init(connection: NSXPCConnection, boot: UUID, role: ProcessRole, owner: @escaping PeerOwnerProvider,
         snapshot: @escaping @Sendable () -> StateSnapshot, command: ServiceCommandHandler?) throws {
        self.owner = owner; self.snapshot = snapshot
        self.command = command; self.role = role
        state = Mutex(State(session: try ServiceSession(bootID: boot, role: role),
                            deadline: Self.deadline(after: 2_000), connection: IncomingPeer(connection)))
    }

    func exchange(_ packet: NSData, reply: @escaping @Sendable (NSData?) -> Void) {
        do {
            guard let connection = state.withLock({ $0.connection }), connection.isCurrent else {
                throw PeerPolicyError.wrongCallingConnection
            }
            let current = try owner(connection.effectiveUserIdentifier, connection.auditSessionIdentifier)
            try current.validate(effectiveUID: connection.effectiveUserIdentifier, auditSession: connection.auditSessionIdentifier)
            guard packet.length <= WireCodec.maximumBytes else { throw WireError.tooLarge }
            let data = Data(bytes: packet.bytes, count: packet.length)
            let now = MonotonicTime.milliseconds
            var (ticket, session) = try state.withLock { state in
                guard now < state.deadline, !state.session.closed, state.pendingExchange == nil else {
                    throw ConnectionBudgetError.timeout
                }
                let ticket = UUID(); state.pendingExchange = ticket
                return (ticket, state.session)
            }
            // The host may hop to its event loop and inspect this same route.
            // Never hold the channel mutex across a host callback.
            let handler: ((WirePayload) throws -> WirePayload)? = command.map { command in
                { payload in try command(ServicePeer(role: self.role, owner: current), payload, now) }
            }
            let response = try session.receive(data, now: now, snapshot: snapshot(), command: handler)
            try state.withLock { state in
                let finished = MonotonicTime.milliseconds
                guard state.pendingExchange == ticket, !state.session.closed,
                      finished >= now, finished - now < 2_000 else { throw ConnectionBudgetError.timeout }
                state.session = session; state.pendingExchange = nil
                if state.session.lockDeliveryNonce != nil { state.deliveryOwner = current }
                if state.session.established { state.deadline = Self.deadline(after: 5_000) }
            }
            reply(response as NSData)
        } catch {
            reply(nil)
            invalidate()
        }
    }

    func invalidate() {
        let connection = state.withLock { state in
            state.session.invalidate()
            state.pendingExchange = nil
            let connection = state.connection; state.connection = nil
            return connection
        }
        connection?.invalidate()
    }

    func expired(at now: UInt64) -> Bool {
        state.withLock { $0.session.closed || now >= $0.deadline }
    }

    func isDeliveryRoute(for requestedOwner: OwnerSessionPolicy) -> Bool {
        guard role == .sessionAgent else { return false }
        return state.withLock { state in
            guard state.session.established, state.session.lockDeliveryNonce != nil,
                  MonotonicTime.milliseconds < state.deadline, let peer = state.connection,
                  let bound = state.deliveryOwner,
                  bound.uid == requestedOwner.uid, bound.auditSession == requestedOwner.auditSession else { return false }
            do {
                let current = try owner(peer.effectiveUserIdentifier, peer.auditSessionIdentifier)
                try current.validate(effectiveUID: bound.uid, auditSession: bound.auditSession)
                return true
            } catch { return false }
        }
    }

    func deliver(_ id: ActionID, to requestedOwner: OwnerSessionPolicy) async throws -> ActionResult {
        guard isDeliveryRoute(for: requestedOwner) else { throw LockTransportError.unavailable }
        let (ticket, delivery, peer) = try state.withLock { state -> (UUID, LockDelivery, IncomingPeer) in
            guard state.session.established, let nonce = state.session.lockDeliveryNonce,
                  let peer = state.connection, state.pendingDelivery == nil,
                  state.deliverySequence < UInt64.max else { throw LockTransportError.busy }
            let current = try owner(peer.effectiveUserIdentifier, peer.auditSessionIdentifier)
            try current.validate(effectiveUID: requestedOwner.uid, auditSession: requestedOwner.auditSession)
            let now = MonotonicTime.milliseconds
            guard now < state.deadline else { throw LockTransportError.expired }
            state.deliverySequence += 1
            let delivery = try LockDelivery(nonce: nonce, sequence: state.deliverySequence, issuedAt: now, id: id)
            let ticket = UUID(); state.pendingDelivery = ticket
            return (ticket, delivery, peer)
        }
        let data = try LockDeliveryCodec.encode(delivery)
        return try await withCheckedThrowingContinuation { continuation in
            let pending = PendingLockReply(continuation)
            let finish: @Sendable (Result<ActionResult, any Error>) -> Void = { [weak self] result in
                pending.finish(result) {
                    self?.state.withLock { state in
                        if state.pendingDelivery == ticket { state.pendingDelivery = nil }
                    }
                    if case .failure = result { self?.invalidate() }
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .seconds(2)) {
                finish(.failure(LockTransportError.timeout))
            }
            peer.deliver(data) { [weak self] response in
                do {
                    guard let self, self.isDeliveryRoute(for: requestedOwner),
                          let response, response.count <= LockDeliveryCodec.maximumBytes else {
                        throw LockTransportError.invalidReply
                    }
                    let reply = try LockDeliveryCodec.decode(LockDeliveryReply.self, from: response)
                    try reply.validate(for: delivery)
                    finish(.success(reply.result))
                } catch { finish(.failure(error)) }
            }
        }
    }

    private static func deadline(after milliseconds: UInt64) -> UInt64 {
        let (value, overflow) = MonotonicTime.milliseconds.addingReportingOverflow(milliseconds)
        return overflow ? 0 : value
    }
}

/// The listener configures the NSXPC connection before activation. Afterwards
/// callback queues only read its OS credentials or invalidate it. Mutable
/// configuration never crosses this bridge; channel lifetime is mutex-owned.
private final class IncomingPeer: @unchecked Sendable {
    private let connection: NSXPCConnection
    init(_ connection: NSXPCConnection) { self.connection = connection }
    var isCurrent: Bool { NSXPCConnection.current() === connection }
    var effectiveUserIdentifier: UInt32 { connection.effectiveUserIdentifier }
    var auditSessionIdentifier: Int32 { connection.auditSessionIdentifier }
    func invalidate() { connection.invalidate() }
    func deliver(_ data: Data, reply: @escaping @Sendable (Data?) -> Void) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in reply(nil) }) as? PullockLockTransport else {
            reply(nil); return
        }
        proxy.deliver(data as NSData) { response in
            guard let response, response.length <= LockDeliveryCodec.maximumBytes else { reply(nil); return }
            reply(Data(bytes: response.bytes, count: response.length))
        }
    }
}

private final class PendingLockReply: Sendable {
    private let continuation: Mutex<CheckedContinuation<ActionResult, any Error>?>
    init(_ continuation: CheckedContinuation<ActionResult, any Error>) { self.continuation = Mutex(continuation) }
    func finish(_ result: Result<ActionResult, any Error>, cleanup: () -> Void) {
        let pending = continuation.withLock { value in let pending = value; value = nil; return pending }
        guard let pending else { return }
        cleanup()
        pending.resume(with: result)
    }
}
