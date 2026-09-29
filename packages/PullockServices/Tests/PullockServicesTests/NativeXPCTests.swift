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

@Test(.timeLimit(.minutes(1))) func nativeXPCPerformsSignedNonceHelloAndHealth() async throws {
    let runtime = try FixtureHealth(), requirement = try ownRequirement()
    let incoming = try ServiceTrust(requirement: requirement, role: .app, development: true)
    let outgoing = try ServiceTrust(requirement: requirement, role: .daemon, development: true)
    let server = NativeHealthListener(testTrust: incoming, boot: runtime.boot, owner: owner, snapshot: runtime.snapshot)
    server.start()
    defer { server.stop() }
    let client = NativeHealthClient(testEndpoint: server.endpoint, trust: outgoing, clientRole: .app, expectedUID: geteuid())
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
    let client = NativeHealthClient(testEndpoint: server.endpoint, trust: outgoing, clientRole: .app, expectedUID: geteuid())
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
    let client = NativeHealthClient(testEndpoint: server.endpoint, trust: outgoing, clientRole: .app, expectedUID: geteuid())
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
    let client = NativeHealthClient(testEndpoint: server.endpoint, trust: outgoing, clientRole: .app, expectedUID: geteuid())
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
        let client = NativeHealthClient(testEndpoint: server.endpoint, trust: outgoing, clientRole: .app, expectedUID: geteuid())
        try await client.connect()
        clients.append(client)
    }
    #expect(server.connectionCount == 8)
    let excess = NativeHealthClient(testEndpoint: server.endpoint, trust: outgoing, clientRole: .app, expectedUID: geteuid())
    await #expect(throws: (any Error).self) { try await excess.connect() }
    await excess.close()
    for client in clients { await client.close() }
    for _ in 0..<100 where server.connectionCount != 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(server.connectionCount == 0)
    let replacement = NativeHealthClient(testEndpoint: server.endpoint, trust: outgoing, clientRole: .app, expectedUID: geteuid())
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
    let client = NativeHealthClient(testEndpoint: server.endpoint, trust: outgoing, clientRole: .app, expectedUID: geteuid())
    try await client.connect()
    try await Task.sleep(for: .milliseconds(5_300))
    await #expect(throws: (any Error).self) { try await client.health() }
    await client.close()
}
