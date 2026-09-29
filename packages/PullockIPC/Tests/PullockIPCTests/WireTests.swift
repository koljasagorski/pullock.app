import Foundation
import Testing
import PullockCore
import PullockIPC

private struct Peer {
    static let boot = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let connection = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    var session: WireSession

    init(local: ProcessRole = .daemon, remote: ProcessRole = .app) {
        session = WireSession(localRole: local, remoteRole: remote, connectionID: Self.connection, bootID: Self.boot)
    }

    func packet(_ payload: WirePayload, sequence: UInt64 = 2, version: Int = 1,
                connection: UUID = Self.connection, boot: UUID = Self.boot) throws -> Data {
        try WireCodec.encode(WireEnvelope(version: version, connectionID: connection,
            bootID: boot, sequence: sequence, payload: payload))
    }

    mutating func hello() throws {
        let data = try packet(.hello(role: session.remoteRole), sequence: 1)
        _ = try session.receive(data, now: 100)
    }
}

@Test func handshakeAndHealthRoundTrip() throws {
    var p = Peer()
    let data = try p.packet(.getHealth)
    #expect(throws: WireError.handshakeRequired) { try p.session.receive(data, now: 100) }
    try p.hello()
    let result = try p.session.receive(data, now: 100)
    #expect(result == .getHealth)
    #expect(p.session.established)
}

@Test func versionConnectionBootAndReplayAreChecked() throws {
    var p = Peer()
    try p.hello()
    let wrongVersion = try p.packet(.getHealth, version: 999)
    #expect(throws: WireError.unsupportedVersion) { try p.session.receive(wrongVersion, now: 100) }
    let wrongConnection = try p.packet(.getHealth, connection: UUID())
    #expect(throws: WireError.wrongConnection) { try p.session.receive(wrongConnection, now: 100) }
    let wrongBoot = try p.packet(.getHealth, boot: UUID())
    #expect(throws: WireError.wrongBoot) { try p.session.receive(wrongBoot, now: 100) }
    let valid = try p.packet(.getHealth)
    _ = try p.session.receive(valid, now: 100)
    #expect(throws: WireError.staleSequence) { try p.session.receive(valid, now: 100) }
}

@Test func claimedRoleCannotReplaceTransportAssignedRole() throws {
    var p = Peer(remote: .sessionAgent)
    let lie = try p.packet(.hello(role: .app), sequence: 1)
    #expect(throws: WireError.roleViolation) { try p.session.receive(lie, now: 100) }
    #expect(!p.session.established)
    try p.hello()
    let arm = try p.packet(.arm(expectedRevision: 1))
    #expect(throws: WireError.roleViolation) { try p.session.receive(arm, now: 100) }
    let disarm = try p.packet(.disarm(expectedArming: 1))
    #expect(throws: WireError.roleViolation) { try p.session.receive(disarm, now: 100) }
}

@Test func wrongDirectionAndSecondHandshakeAreRejected() throws {
    var p = Peer()
    try p.hello()
    let second = try p.packet(.hello(role: .app))
    #expect(throws: WireError.duplicateHandshake) { try p.session.receive(second, now: 100) }
    let id = ActionID(trigger: TriggerID(boot: Peer.boot, arming: 1), kind: .lock, cause: .removal)
    let lock = try p.packet(.performLock(id: id))
    #expect(throws: WireError.roleViolation) { try p.session.receive(lock, now: 100) }
}

@Test func malformedOversizedAndUnknownOperationsAreRejected() throws {
    #expect(throws: WireError.tooLarge) { try WireCodec.decode(Data(repeating: 0x20, count: 16_385)) }
    #expect(throws: WireError.malformed) { try WireCodec.decode(Data("{".utf8)) }
    let p = Peer()
    let data = try p.packet(.getHealth)
    var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    json["shell"] = "/sbin/shutdown"
    let extra = try JSONSerialization.data(withJSONObject: json)
    #expect(throws: WireError.unknownFields) { try WireCodec.decode(extra) }
    json.removeValue(forKey: "shell")
    json["payload"] = ["execute": ["command": "ignored"]]
    let unknown = try JSONSerialization.data(withJSONObject: json)
    #expect(throws: WireError.unknownFields) { try WireCodec.decode(unknown) }
}

@Test func configuredPolicyIsValidatedBeforeDispatch() throws {
    var p = Peer()
    try p.hello()
    let enrollment = try Enrollment(id: UUID(), vendorID: 0x1050, acceptedProductIDs: [0x0407], serial: "FIXTURE")
    let policy = try ProtectionPolicy(revision: 1, enrollment: enrollment)
    let packet = try p.packet(.configure(policy: policy, expectedRevision: nil))
    var root = try #require(JSONSerialization.jsonObject(with: packet) as? [String: Any])
    var policyObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as? [String: Any])
    var identity = try #require(policyObject["enrollment"] as? [String: Any])
    identity["serial"] = ""
    policyObject["enrollment"] = identity
    root["payload"] = ["configure": ["policy": policyObject]]
    let invalid = try JSONSerialization.data(withJSONObject: root)
    #expect(throws: WireError.invalidPayload) { try p.session.receive(invalid, now: 100) }
    _ = try p.session.receive(packet, now: 100)
}

@Test func shutdownCannotTravelThroughTheLockChannel() throws {
    var p = Peer(local: .sessionAgent, remote: .daemon)
    try p.hello()
    let shutdown = ActionID(trigger: TriggerID(boot: Peer.boot, arming: 1), kind: .shutdown, cause: .removal)
    let packet = try p.packet(.performLock(id: shutdown))
    #expect(throws: WireError.invalidPayload) { try p.session.receive(packet, now: 100) }
    let lock = ActionID(trigger: TriggerID(boot: Peer.boot, arming: 1), kind: .lock, cause: .removal)
    let valid = try p.packet(.performLock(id: lock))
    #expect(try p.session.receive(valid, now: 100) == .performLock(id: lock))
}

@Test func staleSnapshotsCannotBecomeCurrentHealth() throws {
    var p = Peer(local: .app, remote: .daemon)
    try p.hello()
    let core = try ProtectionReducer(bootID: Peer.boot)
    let packet = try p.packet(.snapshot(state: core.snapshot))
    #expect(throws: WireError.staleSnapshot) { try p.session.receive(packet, now: 3_000) }
    let accepted = try p.session.receive(packet, now: 100)
    #expect(accepted == .snapshot(state: core.snapshot))
}

@Test func deviceInventoryRequiresAppRoleFreshStateAndUniqueValidDescriptors() throws {
    let device = WireDevice(instance: 1, vendorID: 0x1234, productID: 0x4321, name: "Test stick")
    let snapshot = try ProtectionReducer(bootID: Peer.boot).snapshot
    var app = Peer(local: .app, remote: .daemon)
    try app.hello()
    let duplicate = try app.packet(.devices(inventory: [device, device], state: snapshot))
    #expect(throws: WireError.invalidPayload) { try app.session.receive(duplicate, now: 100) }
    let invalid = try app.packet(.devices(inventory: [WireDevice(instance: 1, vendorID: 1, productID: 1, name: "bad\nname")], state: snapshot))
    #expect(throws: WireError.invalidPayload) { try app.session.receive(invalid, now: 100) }
    let valid = try app.packet(.devices(inventory: [device], state: snapshot))
    #expect(throws: WireError.staleSnapshot) { try app.session.receive(valid, now: 3_000) }
    #expect(try app.session.receive(valid, now: 100) == .devices(inventory: [device], state: snapshot))
    var agent = Peer(remote: .sessionAgent)
    try agent.hello()
    #expect(throws: WireError.roleViolation) { try agent.session.receive(agent.packet(.getDevices), now: 100) }
}

@Test func connectionPolicyRejectsNestedExtraFieldsBeforeDispatch() throws {
    var p = Peer()
    try p.hello()
    let selection = try ConnectionIdentity(bootID: Peer.boot, watcher: 1, power: 0, instance: 42)
    let enrollment = try Enrollment(id: UUID(), vendorID: 0x1234, productID: 0x4321, connection: selection)
    let policy = try ProtectionPolicy(revision: 1, enrollment: enrollment)
    let packet = try p.packet(.configure(policy: policy, expectedRevision: nil))
    var root = try #require(JSONSerialization.jsonObject(with: packet) as? [String: Any])
    var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as? [String: Any])
    var identity = try #require(encoded["enrollment"] as? [String: Any])
    var connection = try #require(identity["connection"] as? [String: Any])
    connection["persistAfterReboot"] = true
    identity["connection"] = connection; encoded["enrollment"] = identity
    root["payload"] = ["configure": ["policy": encoded]]
    let extra = try JSONSerialization.data(withJSONObject: root)
    #expect(throws: WireError.unknownFields) { try p.session.receive(extra, now: 100) }
    _ = try p.session.receive(packet, now: 100)
}

@Test func replacingConnectionRequiresFreshHandshakeAndNonce() throws {
    var p = Peer()
    try p.hello()
    let oldPacket = try p.packet(.getHealth)
    var replacement = WireSession(localRole: .daemon, remoteRole: .app, connectionID: UUID(), bootID: Peer.boot)
    #expect(throws: WireError.wrongConnection) { try replacement.receive(oldPacket, now: 100) }
    #expect(!replacement.established)
}

@Test func zeroProgressHeartbeatIsRejected() throws {
    var p = Peer(remote: .sessionAgent)
    try p.hello()
    let zero = try p.packet(.sessionHeartbeat(generation: 1, progress: 0))
    #expect(throws: WireError.invalidPayload) { try p.session.receive(zero, now: 100) }
    let valid = try p.packet(.sessionHeartbeat(generation: 1, progress: 1))
    _ = try p.session.receive(valid, now: 100)
}

@Test func nestedExtraFieldsAndImpossibleArmedSnapshotsAreRejected() throws {
    var p = Peer(local: .app, remote: .daemon)
    try p.hello()
    let core = try ProtectionReducer(bootID: Peer.boot)
    let data = try p.packet(.snapshot(state: core.snapshot))
    var root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var state = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(core.snapshot)) as? [String: Any])
    state["undocumentedOverride"] = true
    root["payload"] = ["snapshot": ["state": state]]
    let extra = try JSONSerialization.data(withJSONObject: root)
    #expect(throws: WireError.unknownFields) { try p.session.receive(extra, now: 100) }
    state.removeValue(forKey: "undocumentedOverride")
    state["status"] = "armed"
    root["payload"] = ["snapshot": ["state": state]]
    let impossible = try JSONSerialization.data(withJSONObject: root)
    #expect(throws: WireError.invalidPayload) { try p.session.receive(impossible, now: 100) }
    let decoded = try JSONDecoder().decode(StateSnapshot.self, from: JSONSerialization.data(withJSONObject: state))
    #expect(!decoded.isProtected(at: 100))
    #expect(decoded.displayStatus(at: 100) == .error)
}
