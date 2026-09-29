import Foundation
import PullockCore
import PullockIPC
import Synchronization

public typealias PeerOwnerProvider = @Sendable (UInt32, Int32) throws -> OwnerSessionPolicy

/// Real NSXPC transport, deliberately restricted to non-sensitive hello/health.
/// It does not expose configuration, USB injection or actions. The owner provider
/// belongs to the trusted host; a client never supplies its policy.
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
    private let timer: DispatchSourceTimer
    public var endpoint: NSXPCListenerEndpoint { listener.endpoint }
    public var connectionCount: Int { state.withLock { $0.channels.count } }

    public init(trust: ServiceTrust, boot: UUID, owner: @escaping PeerOwnerProvider,
                snapshot: @escaping @Sendable () -> StateSnapshot) throws {
        guard trust.role != .daemon else { throw PeerPolicyError.invalidRole }
        self.trust = trust; self.boot = boot; self.owner = owner; self.snapshot = snapshot
        let suffix = trust.role == .app ? "app" : "session-agent"
        let prefix = trust.development ? "app.pullock.daemon.development" : "app.pullock.daemon"
        listener = NSXPCListener(machServiceName: "\(prefix).\(suffix)")
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "app.pullock.connection-deadlines"))
        super.init()
        configure()
    }

    init(testTrust: ServiceTrust, boot: UUID, owner: @escaping PeerOwnerProvider,
         snapshot: @escaping @Sendable () -> StateSnapshot) {
        trust = testTrust; self.boot = boot; self.owner = owner; self.snapshot = snapshot
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

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        do {
            let current = try owner(connection.effectiveUserIdentifier, connection.auditSessionIdentifier)
            try current.validate(effectiveUID: connection.effectiveUserIdentifier, auditSession: connection.auditSessionIdentifier)
            connection.setCodeSigningRequirement(trust.requirement)
            let id = UUID()
            let channel = try HealthChannel(connection: connection, boot: boot, role: trust.role, owner: owner, snapshot: snapshot)
            let accepted = state.withLock { state in
                guard state.running, !state.stopped, state.channels.count < 8 else { return false }
                state.channels[id] = channel
                return true
            }
            guard accepted else { return false }
            connection.exportedInterface = PullockXPCInterface.make()
            connection.exportedObject = channel
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
    private struct State { var session: ServiceSession; var deadline: UInt64; var connection: IncomingPeer? }
    private let state: Mutex<State>
    private let owner: PeerOwnerProvider
    private let snapshot: @Sendable () -> StateSnapshot

    init(connection: NSXPCConnection, boot: UUID, role: ProcessRole, owner: @escaping PeerOwnerProvider,
         snapshot: @escaping @Sendable () -> StateSnapshot) throws {
        self.owner = owner; self.snapshot = snapshot
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
            let response = try state.withLock { state in
                let view = snapshot()
                let now = MonotonicTime.milliseconds
                guard now < state.deadline else { throw ConnectionBudgetError.timeout }
                let value = try state.session.receive(data, now: now, snapshot: view)
                let finished = MonotonicTime.milliseconds
                guard finished >= now, finished - now < 2_000 else { throw ConnectionBudgetError.timeout }
                if state.session.established { state.deadline = Self.deadline(after: 5_000) }
                return value
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
            let connection = state.connection; state.connection = nil
            return connection
        }
        connection?.invalidate()
    }

    func expired(at now: UInt64) -> Bool {
        state.withLock { $0.session.closed || now >= $0.deadline }
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
}
