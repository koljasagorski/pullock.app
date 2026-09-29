import Darwin
import Foundation
import PullockCore
import PullockIPC
@testable import PullockServices
import Security
import Synchronization
import Testing

private final class FixtureHealth: Sendable {
    let boot = UUID()
    private struct State { var core: ProtectionReducer; var sequence: UInt64 = 0 }
    private let state: Mutex<State>
    init() throws { state = Mutex(State(core: try ProtectionReducer(bootID: boot))) }
    func snapshot() -> StateSnapshot {
        state.withLock { state in
            state.sequence += 1
            let now = MonotonicTime.milliseconds
            return state.core.process(EventEnvelope(bootID: boot, source: .clock, sequence: state.sequence,
                observedAt: now, event: .tick), at: now).snapshot
        }
    }
}

private func ownRequirement() throws -> String {
    var own: SecCode?
    #expect(SecCodeCopySelf([], &own) == errSecSuccess)
    let code = try #require(own)
    var staticCode: SecStaticCode?
    #expect(SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess)
    var information: CFDictionary?
    #expect(SecCodeCopySigningInformation(try #require(staticCode), SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess)
    let fields = try #require(information as? [String: Any])
    let digest = try #require(fields[kSecCodeInfoUnique as String] as? Data)
    #expect(digest.count == 20)
    return "cdhash H\"\(digest.map { String(format: "%02x", $0) }.joined())\""
}

private func owner(uid: UInt32, session: Int32) throws -> OwnerSessionPolicy {
    try OwnerSessionPolicy(uid: geteuid(), auditSession: session, active: true)
}

private final class ReverseRecord: Sendable {
    let calls = Mutex<[ActionID]>([])
    let owner = Mutex<OwnerSessionPolicy?>(nil)
    let active = Mutex(true)
}

private final class ReverseFixture: Sendable {
    let health: FixtureHealth
    let listener: NativeHealthListener
    let trust: ServiceTrust
    let record = ReverseRecord()
    init() throws {
        health = try FixtureHealth()
        let requirement = try ownRequirement()
        trust = try ServiceTrust(requirement: requirement, role: .daemon, development: true)
        let incoming = try ServiceTrust(requirement: requirement, role: .sessionAgent, development: true)
        let record = self.record
        listener = NativeHealthListener(testTrust: incoming, boot: health.boot, owner: { uid, session in
            let current = try OwnerSessionPolicy(uid: uid, auditSession: session, active: record.active.withLock { $0 })
            record.owner.withLock { $0 = current }
            return current
        }, snapshot: health.snapshot)
        listener.start()
    }
    deinit { listener.stop() }
    func receiver() async -> NativeLockReceiver {
        let record = self.record
        let executor = await MainActor.run {
            LockActionExecutor { id in record.calls.withLock { $0.append(id) }; return .unknown }
        }
        return NativeLockReceiver(executor: executor)
    }
    func client(_ receiver: NativeLockReceiver) throws -> NativeHealthClient {
        try NativeHealthClient(testEndpoint: listener.endpoint, trust: trust,
            clientRole: .sessionAgent, expectedUID: geteuid(), lockReceiver: receiver)
    }
    var selectedOwner: OwnerSessionPolicy { get throws { try #require(record.owner.withLock { $0 }) } }
    var request: ActionRequest {
        ActionRequest(id: ActionID(trigger: TriggerID(boot: health.boot, arming: 1), kind: .lock, cause: .removal), profile: .live)
    }
}

@Test(.timeLimit(.minutes(1))) func nativeReverseLockUsesSignedConnectionAndDeduplicatesAfterReconnect() async throws {
    let fixture = try ReverseFixture()
    let actualReceiver = await fixture.receiver()
    let client = try fixture.client(actualReceiver)
    try await client.connect()
    let owner = try fixture.selectedOwner
    #expect(!fixture.listener.lockRouteAvailable(for: owner))
    _ = try await client.enableLockDelivery()
    #expect(fixture.listener.lockRouteAvailable(for: owner))
    let first = try await fixture.listener.deliverLock(fixture.request, owner: owner)
    #expect(first.outcome == .unknown && first.id == fixture.request.id)
    _ = try await fixture.listener.deliverLock(fixture.request, owner: owner)
    #expect(fixture.record.calls.withLock { $0.count } == 1)
    await client.close()
    for _ in 0..<100 where fixture.listener.connectionCount != 0 { try await Task.sleep(for: .milliseconds(10)) }
    let replacement = try fixture.client(actualReceiver)
    try await replacement.connect()
    _ = try await replacement.enableLockDelivery()
    _ = try await fixture.listener.deliverLock(fixture.request, owner: owner)
    #expect(fixture.record.calls.withLock { $0.count } == 1)
    await replacement.close()
}

@Test(.timeLimit(.minutes(1))) func nativeReverseLockRejectsAmbiguousAgentsAndLostOwner() async throws {
    let fixture = try ReverseFixture()
    let first = try await fixture.client(fixture.receiver())
    let second = try await fixture.client(fixture.receiver())
    try await first.connect(); _ = try await first.enableLockDelivery()
    try await second.connect(); _ = try await second.enableLockDelivery()
    let owner = try fixture.selectedOwner
    #expect(!fixture.listener.lockRouteAvailable(for: owner))
    await #expect(throws: LockTransportError.unavailable) { try await fixture.listener.deliverLock(fixture.request, owner: owner) }
    await second.close()
    for _ in 0..<100 where fixture.listener.connectionCount != 1 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(fixture.listener.lockRouteAvailable(for: owner))
    fixture.record.active.withLock { $0 = false }
    #expect(!fixture.listener.lockRouteAvailable(for: owner))
    await #expect(throws: LockTransportError.unavailable) { try await fixture.listener.deliverLock(fixture.request, owner: owner) }
    #expect(fixture.record.calls.withLock { $0.isEmpty })
    await first.close()
}

@Test(.timeLimit(.minutes(1))) func nativeReverseLockCancelsQueuedWorkOnDisconnect() async throws {
    let fixture = try ReverseFixture()
    let actualReceiver = await fixture.receiver()
    let client = try fixture.client(actualReceiver)
    try await client.connect(); _ = try await client.enableLockDelivery()
    let owner = try fixture.selectedOwner
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    await withCheckedContinuation { (entered: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async { entered.resume(); _ = release.wait(timeout: .now() + .seconds(5)) }
    }
    let action = Task { try await fixture.listener.deliverLock(fixture.request, owner: owner) }
    for _ in 0..<100 where !actualReceiver.hasPendingDelivery { try await Task.sleep(for: .milliseconds(5)) }
    #expect(actualReceiver.hasPendingDelivery)
    await client.close()
    release.signal()
    await #expect(throws: (any Error).self) { try await action.value }
    for _ in 0..<100 where actualReceiver.hasPendingDelivery { try await Task.sleep(for: .milliseconds(5)) }
    #expect(!actualReceiver.hasPendingDelivery)
    #expect(fixture.record.calls.withLock { $0.isEmpty })
}

@Test(.timeLimit(.minutes(1))) func nativeReverseLockRequiresAgentExportAndExpectedServerUID() async throws {
    let fixture = try ReverseFixture(), receiver = await fixture.receiver()
    #expect(throws: PeerPolicyError.invalidRole) {
        try NativeHealthClient(testEndpoint: fixture.listener.endpoint, trust: fixture.trust,
            clientRole: .app, expectedUID: geteuid(), lockReceiver: receiver)
    }
    let wrongUser = try NativeHealthClient(testEndpoint: fixture.listener.endpoint, trust: fixture.trust,
        clientRole: .sessionAgent, expectedUID: geteuid() + 1, lockReceiver: receiver)
    await #expect(throws: HealthClientError.wrongServerUser) { try await wrongUser.connect() }
    #expect(fixture.record.calls.withLock { $0.isEmpty })
    await wrongUser.close()
}

@Test(.timeLimit(.minutes(1))) func nativeXPCPerformsSignedNonceHelloAndHealth() async throws {
    let runtime = try FixtureHealth(), requirement = try ownRequirement()
    let incoming = try ServiceTrust(requirement: requirement, role: .app, development: true)
    let outgoing = try ServiceTrust(requirement: requirement, role: .daemon, development: true)
    let server = NativeHealthListener(testTrust: incoming, boot: runtime.boot, owner: owner, snapshot: runtime.snapshot)
    server.start()
    defer { server.stop() }
    let client = try NativeHealthClient(testEndpoint: server.endpoint, trust: outgoing, clientRole: .app, expectedUID: geteuid())
    try await client.connect()
    let first = try await client.health(), second = try await client.health()
    #expect(first.bootID == runtime.boot && first.profile == .live && first.status == .error)
    #expect(!first.isProtected(at: MonotonicTime.milliseconds))
    #expect(second.revision > first.revision)
    #expect(server.connectionCount == 1)
    await client.close()
}

@Test(.timeLimit(.minutes(1))) func nativeXPCRejectsIncorrectServerSigningRequirement() async throws {
    let runtime = try FixtureHealth()
    let incoming = try ServiceTrust(requirement: ownRequirement(), role: .app, development: true)
    let outgoing = try ServiceTrust(requirement: "identifier \"invalid.pullock.test\"", role: .daemon, development: true)
    let server = NativeHealthListener(testTrust: incoming, boot: runtime.boot, owner: owner, snapshot: runtime.snapshot)
    server.start()
    defer { server.stop() }
    let client = try NativeHealthClient(testEndpoint: server.endpoint, trust: outgoing, clientRole: .app, expectedUID: geteuid())
    await #expect(throws: (any Error).self) { try await client.connect() }
    await client.close()
}

@Test(.timeLimit(.minutes(1))) func nativeXPCRejectsIncorrectClientSigningRequirement() async throws {
    let runtime = try FixtureHealth()
    let incoming = try ServiceTrust(requirement: "identifier \"invalid.pullock.test\"", role: .app, development: true)
    let outgoing = try ServiceTrust(requirement: ownRequirement(), role: .daemon, development: true)
    let server = NativeHealthListener(testTrust: incoming, boot: runtime.boot, owner: owner, snapshot: runtime.snapshot)
    server.start()
    defer { server.stop() }
    let client = try NativeHealthClient(testEndpoint: server.endpoint, trust: outgoing, clientRole: .app, expectedUID: geteuid())
    await #expect(throws: (any Error).self) { try await client.connect() }
    await client.close()
}

@Test(.timeLimit(.minutes(1))) func nativeXPCRechecksOwnerOnExistingConnection() async throws {
    let runtime = try FixtureHealth(), active = Mutex(true)
    let requirement = try ownRequirement()
    let incoming = try ServiceTrust(requirement: requirement, role: .app, development: true)
    let outgoing = try ServiceTrust(requirement: requirement, role: .daemon, development: true)
    let server = NativeHealthListener(testTrust: incoming, boot: runtime.boot, owner: { _, session in
        try OwnerSessionPolicy(uid: geteuid(), auditSession: session, active: active.withLock { $0 })
    }, snapshot: runtime.snapshot)
    server.start()
    defer { server.stop() }
    let client = try NativeHealthClient(testEndpoint: server.endpoint, trust: outgoing, clientRole: .app, expectedUID: geteuid())
    try await client.connect()
    _ = try await client.health()
    active.withLock { $0 = false }
    await #expect(throws: (any Error).self) { try await client.health() }
    await client.close()
}

@Test(.timeLimit(.minutes(1))) func nativeXPCBoundsConnectionsAndReleasesSlots() async throws {
    let runtime = try FixtureHealth(), requirement = try ownRequirement()
    let incoming = try ServiceTrust(requirement: requirement, role: .app, development: true)
    let outgoing = try ServiceTrust(requirement: requirement, role: .daemon, development: true)
    let server = NativeHealthListener(testTrust: incoming, boot: runtime.boot, owner: owner, snapshot: runtime.snapshot)
    server.start()
    defer { server.stop() }
    var clients: [NativeHealthClient] = []
    for _ in 0..<8 {
        let client = try NativeHealthClient(testEndpoint: server.endpoint, trust: outgoing, clientRole: .app, expectedUID: geteuid())
        try await client.connect()
        clients.append(client)
    }
    #expect(server.connectionCount == 8)
    let excess = try NativeHealthClient(testEndpoint: server.endpoint, trust: outgoing, clientRole: .app, expectedUID: geteuid())
    await #expect(throws: (any Error).self) { try await excess.connect() }
    await excess.close()
    for client in clients { await client.close() }
    for _ in 0..<100 where server.connectionCount != 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(server.connectionCount == 0)
    let replacement = try NativeHealthClient(testEndpoint: server.endpoint, trust: outgoing, clientRole: .app, expectedUID: geteuid())
    try await replacement.connect()
    await replacement.close()
}

@Test(.timeLimit(.minutes(1))) func nativeXPCIdleDeadlineInvalidatesConnection() async throws {
    let runtime = try FixtureHealth(), requirement = try ownRequirement()
    let incoming = try ServiceTrust(requirement: requirement, role: .app, development: true)
    let outgoing = try ServiceTrust(requirement: requirement, role: .daemon, development: true)
    let server = NativeHealthListener(testTrust: incoming, boot: runtime.boot, owner: owner, snapshot: runtime.snapshot)
    server.start()
    defer { server.stop() }
    let client = try NativeHealthClient(testEndpoint: server.endpoint, trust: outgoing, clientRole: .app, expectedUID: geteuid())
    try await client.connect()
    try await Task.sleep(for: .milliseconds(5_300))
    await #expect(throws: (any Error).self) { try await client.health() }
    await client.close()
}

@Test(.timeLimit(.minutes(1))) func nativeCommandsCarryOSCredentialsAndCannotClaimAnotherRole() async throws {
    let runtime = try FixtureHealth(), requirement = try ownRequirement()
    let incoming = try ServiceTrust(requirement: requirement, role: .app, development: true)
    let outgoing = try ServiceTrust(requirement: requirement, role: .daemon, development: true)
    let received = Mutex<[ProcessRole]>([])
    let server = NativeHealthListener(testTrust: incoming, boot: runtime.boot, owner: owner, snapshot: runtime.snapshot,
        command: { peer, payload, _ in
            #expect(peer.owner.uid == geteuid() && peer.owner.auditSession > 0)
            received.withLock { $0.append(peer.role) }
            guard payload == .getDevices else { throw AuthorityError.unauthorized }
            return .devices(inventory: [WireDevice(instance: 12, vendorID: 0x1234, productID: 0x4321, name: "Fixture")],
                state: runtime.snapshot())
        })
    server.start()
    defer { server.stop() }
    let client = try NativeHealthClient(testEndpoint: server.endpoint, trust: outgoing, clientRole: .app, expectedUID: geteuid())
    try await client.connect()
    guard case let .devices(inventory, _) = try await client.request(.getDevices) else {
        Issue.record("Expected bounded device projection"); return
    }
    #expect(inventory.count == 1 && inventory.first?.instance == 12)
    await #expect(throws: (any Error).self) {
        try await client.request(.sessionHeartbeat(generation: 1, progress: 1))
    }
    #expect(received.withLock { $0 } == [.app])
    await client.close()
}
