import Foundation
import PullockCore
import PullockIPC
import Synchronization

public enum HealthClientError: String, Error, Sendable { case disconnected, busy, transport, timeout, invalidReply, wrongServerUser }

/// One actor serializes the wire sequence. The server enforces each connection's
/// fixed role. OS signing requirements apply before activation.
public actor NativeHealthClient {
    private let connection: NSXPCConnection
    private let role: ProcessRole
    private let expectedServerUID: UInt32
    private var wire: WireSession?
    private var sequence: UInt64 = 0
    private var busy = false
    private var closed = false

    public init(trust: ServiceTrust, clientRole: ProcessRole) throws {
        guard trust.role == .daemon, clientRole != .daemon else { throw PeerPolicyError.invalidRole }
        let prefix = trust.development ? "app.pullock.daemon.development" : "app.pullock.daemon"
        let suffix = clientRole == .app ? "app" : "session-agent"
        connection = NSXPCConnection(machServiceName: "\(prefix).\(suffix)", options: .privileged)
        role = clientRole; expectedServerUID = 0
        connection.setCodeSigningRequirement(trust.requirement)
        connection.remoteObjectInterface = PullockXPCInterface.make()
    }

    init(testEndpoint: NSXPCListenerEndpoint, trust: ServiceTrust, clientRole: ProcessRole, expectedUID: UInt32) {
        connection = NSXPCConnection(listenerEndpoint: testEndpoint)
        role = clientRole; expectedServerUID = expectedUID
        connection.setCodeSigningRequirement(trust.requirement)
        connection.remoteObjectInterface = PullockXPCInterface.make()
    }

    isolated deinit { connection.invalidate() }

    public func connect() async throws {
        guard !closed, wire == nil else { throw HealthClientError.disconnected }
        guard !busy else { throw HealthClientError.busy }
        busy = true
        defer { busy = false }
        do {
            connection.activate()
            let request = BootstrapRequest()
            let bootstrapData = try await exchange(BootstrapCodec.encode(request))
            let bootstrap = try BootstrapCodec.reply(bootstrapData, expectedNonce: request.nonce)
            var session = WireSession(localRole: role, remoteRole: .daemon,
                                      connectionID: bootstrap.connectionID, bootID: bootstrap.bootID)
            let hello = WireEnvelope(connectionID: bootstrap.connectionID, bootID: bootstrap.bootID,
                                     sequence: 1, payload: .hello(role: role))
            let helloData = try await exchange(WireCodec.encode(hello))
            guard try session.receive(helloData, now: MonotonicTime.milliseconds) == .hello(role: .daemon) else {
                throw HealthClientError.invalidReply
            }
            guard !closed else { throw HealthClientError.disconnected }
            wire = session; sequence = 1
        } catch { close(); throw error }
    }

    public func health() async throws -> StateSnapshot {
        let result = try await request(.getHealth)
        guard case let .snapshot(snapshot) = result else { close(); throw HealthClientError.invalidReply }
        return snapshot
    }

    /// WireSession on the server still enforces this connection's fixed role;
    /// unsupported operations close the connection. No role can be upgraded.
    public func request(_ payload: WirePayload) async throws -> WirePayload {
        guard !closed, let current = wire else { throw HealthClientError.disconnected }
        guard !busy else { throw HealthClientError.busy }
        busy = true
        defer { busy = false }
        do {
            guard sequence < UInt64.max else { throw HealthClientError.disconnected }
            sequence += 1
            let request = WireEnvelope(connectionID: current.connectionID, bootID: current.bootID,
                                       sequence: sequence, payload: payload)
            let data = try await exchange(WireCodec.encode(request))
            guard !closed, var session = wire else { throw HealthClientError.disconnected }
            let payload = try session.receive(data, now: MonotonicTime.milliseconds)
            wire = session
            return payload
        } catch { close(); throw error }
    }

    public func close() {
        closed = true; wire = nil
        connection.invalidate()
    }

    private func exchange(_ data: Data) async throws -> Data {
        let connection = self.connection, expectedUID = expectedServerUID
        let peer = ReplyPeer(connection)
        return try await withCheckedThrowingContinuation { continuation in
            let reply = ReplyOnce(continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(2)) {
                if reply.complete(.failure(HealthClientError.timeout)) { peer.invalidate() }
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                reply.complete(.failure(HealthClientError.transport))
            }) as? PullockXPCTransport else {
                reply.complete(.failure(HealthClientError.transport)); return
            }
            proxy.exchange(data as NSData) { response in
                guard peer.effectiveUID == expectedUID else {
                    reply.complete(.failure(HealthClientError.wrongServerUser)); return
                }
                guard let response, response.length <= WireCodec.maximumBytes else {
                    reply.complete(.failure(HealthClientError.invalidReply)); return
                }
                reply.complete(.success(Data(bytes: response.bytes, count: response.length)))
            }
        }
    }
}

/// NSXPC's receive-side credential getter and invalidation are used from its
/// callback queue/timeout queue. Configuration and sends stay actor-isolated;
/// this narrow bridge never exposes mutable connection configuration.
private final class ReplyPeer: @unchecked Sendable {
    private let connection: NSXPCConnection
    init(_ connection: NSXPCConnection) { self.connection = connection }
    var effectiveUID: UInt32 { connection.effectiveUserIdentifier }
    func invalidate() { connection.invalidate() }
}

private final class ReplyOnce: Sendable {
    private let continuation: Mutex<CheckedContinuation<Data, any Error>?>
    init(_ continuation: CheckedContinuation<Data, any Error>) { self.continuation = Mutex(continuation) }
    @discardableResult func complete(_ value: Result<Data, any Error>) -> Bool {
        let pending = continuation.withLock { current in
            let pending = current; current = nil; return pending
        }
        guard let pending else { return false }
        pending.resume(with: value)
        return true
    }
}
