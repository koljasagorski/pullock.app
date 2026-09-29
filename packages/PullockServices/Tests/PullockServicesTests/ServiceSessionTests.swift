import Foundation
import PullockCore
import PullockIPC
@testable import PullockServices
import Testing

private func snapshot(_ boot: UUID, at now: UInt64 = 0) throws -> StateSnapshot {
    var core = try ProtectionReducer(bootID: boot)
    return core.process(EventEnvelope(bootID: boot, source: .clock, sequence: 1, observedAt: now, event: .tick), at: now).snapshot
}

@Test func bootstrapCreatesFreshServerEpochAndChecksNonce() throws {
    let boot = UUID(), request = BootstrapRequest()
    var first = try ServiceSession(bootID: boot, role: .app)
    var second = try ServiceSession(bootID: boot, role: .app)
    let input = try BootstrapCodec.encode(request)
    let one = try first.receive(input, now: 0, snapshot: snapshot(boot))
    let two = try second.receive(input, now: 0, snapshot: snapshot(boot))
    let a = try BootstrapCodec.reply(one, expectedNonce: request.nonce)
    let b = try BootstrapCodec.reply(two, expectedNonce: request.nonce)
    #expect(a.connectionID != b.connectionID && a.bootID == boot)
    #expect(throws: WireError.wrongConnection) { try BootstrapCodec.reply(one, expectedNonce: UUID()) }
}

@Test func helloThenHealthNeverClaimsProtection() throws {
    let boot = UUID()
    var session = try ServiceSession(bootID: boot, role: .app)
    _ = try session.receive(BootstrapCodec.encode(BootstrapRequest()), now: 0, snapshot: snapshot(boot))
    let hello = WireEnvelope(connectionID: session.id, bootID: boot, sequence: 1, payload: .hello(role: .app))
    let reply = try WireCodec.decode(session.receive(WireCodec.encode(hello), now: 1, snapshot: snapshot(boot, at: 1)))
    #expect(reply.payload == .hello(role: .daemon))
    #expect(session.established)
    let health = WireEnvelope(connectionID: session.id, bootID: boot, sequence: 2, payload: .getHealth)
    let response = try WireCodec.decode(session.receive(WireCodec.encode(health), now: 2, snapshot: snapshot(boot, at: 2)))
    guard case let .snapshot(value) = response.payload else { Issue.record("Missing snapshot"); return }
    #expect(value.status == .error && !value.isProtected(at: 2))
}

@Test func unsupportedActionClosesRealTransportSession() throws {
    let boot = UUID()
    var session = try ServiceSession(bootID: boot, role: .app)
    _ = try session.receive(BootstrapCodec.encode(BootstrapRequest()), now: 0, snapshot: snapshot(boot))
    let hello = WireEnvelope(connectionID: session.id, bootID: boot, sequence: 1, payload: .hello(role: .app))
    _ = try session.receive(WireCodec.encode(hello), now: 0, snapshot: snapshot(boot))
    let arm = WireEnvelope(connectionID: session.id, bootID: boot, sequence: 2, payload: .arm(expectedRevision: 1))
    #expect(throws: ServiceSessionError.operationUnavailable) {
        try session.receive(WireCodec.encode(arm), now: 0, snapshot: snapshot(boot))
    }
    #expect(session.closed)
}

@Test func roleClaimsAndBootstrapReplayCloseConnection() throws {
    let boot = UUID(), request = BootstrapRequest()
    var session = try ServiceSession(bootID: boot, role: .app)
    _ = try session.receive(BootstrapCodec.encode(request), now: 0, snapshot: snapshot(boot))
    let wrong = WireEnvelope(connectionID: session.id, bootID: boot, sequence: 1, payload: .hello(role: .sessionAgent))
    #expect(throws: WireError.roleViolation) { try session.receive(WireCodec.encode(wrong), now: 0, snapshot: snapshot(boot)) }
    #expect(session.closed)
    var replay = try ServiceSession(bootID: boot, role: .app)
    _ = try replay.receive(BootstrapCodec.encode(request), now: 0, snapshot: snapshot(boot))
    #expect(throws: WireError.unknownFields) { try replay.receive(BootstrapCodec.encode(request), now: 0, snapshot: snapshot(boot)) }
}

@Test func bootstrapRejectsExtrasOversizeAndWrongVersion() throws {
    let request = BootstrapRequest()
    var object = try #require(JSONSerialization.jsonObject(with: BootstrapCodec.encode(request)) as? [String: Any])
    object["ownerUID"] = 0
    #expect(throws: WireError.unknownFields) { try BootstrapCodec.request(JSONSerialization.data(withJSONObject: object)) }
    object.removeValue(forKey: "ownerUID"); object["version"] = 99
    #expect(throws: WireError.unsupportedVersion) { try BootstrapCodec.request(JSONSerialization.data(withJSONObject: object)) }
    #expect(throws: WireError.tooLarge) { try BootstrapCodec.request(Data(repeating: 0, count: 513)) }
}
