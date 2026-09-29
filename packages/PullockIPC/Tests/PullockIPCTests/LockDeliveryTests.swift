import Foundation
import PullockCore
@testable import PullockIPC
import Testing

private func delivery() throws -> LockDelivery {
    try LockDelivery(nonce: UUID(), sequence: 1, issuedAt: 100,
        id: ActionID(trigger: TriggerID(boot: UUID(), arming: 1), kind: .lock, cause: .removal))
}

@Test func lockDeliveryBindsNonceBootSequenceAndDeadline() throws {
    let command = try delivery()
    let data = try LockDeliveryCodec.encode(command)
    let decoded = try LockDeliveryCodec.decode(LockDelivery.self, from: data)
    #expect(decoded == command)
    try decoded.validate(nonce: command.nonce, boot: command.boot, after: 0, now: 101)
    #expect(throws: WireError.wrongConnection) { try decoded.validate(nonce: UUID(), boot: command.boot, after: 0, now: 101) }
    #expect(throws: WireError.wrongBoot) { try decoded.validate(nonce: command.nonce, boot: UUID(), after: 0, now: 101) }
    #expect(throws: WireError.staleSequence) { try decoded.validate(nonce: command.nonce, boot: command.boot, after: 1, now: 101) }
    for now: UInt64 in [99, 2_100] {
        #expect(throws: WireError.invalidPayload) { try decoded.validate(nonce: command.nonce, boot: command.boot, after: 0, now: now) }
    }
}

@Test func lockDeliveryRejectsUnknownNestedFieldsAndOversize() throws {
    let command = try delivery()
    var object = try #require(JSONSerialization.jsonObject(with: LockDeliveryCodec.encode(command)) as? [String: Any])
    var id = try #require(object["id"] as? [String: Any]); id["shell"] = "ignored"
    object["id"] = id
    #expect(throws: WireError.unknownFields) {
        try LockDeliveryCodec.decode(LockDelivery.self, from: JSONSerialization.data(withJSONObject: object))
    }
    #expect(throws: WireError.tooLarge) { try LockDeliveryCodec.decode(LockDelivery.self, from: Data(repeating: 0, count: 1_025)) }
    #expect(throws: WireError.invalidPayload) {
        try LockDelivery(nonce: UUID(), sequence: 1, issuedAt: UInt64.max, id: command.id)
    }
}

@Test func lockReplyCanOnlyReportMatchingUnknownOrFailed() throws {
    let command = try delivery()
    for outcome: ActionOutcome in [.unknown, .failed] {
        let reply = try LockDeliveryReply(delivery: command, result: ActionResult(id: command.id, outcome: outcome))
        try LockDeliveryCodec.decode(LockDeliveryReply.self, from: LockDeliveryCodec.encode(reply)).validate(for: command)
    }
    for outcome: ActionOutcome in [.confirmed, .simulated, .submitted] {
        #expect(throws: WireError.invalidPayload) { try LockDeliveryReply(delivery: command, result: ActionResult(id: command.id, outcome: outcome)) }
    }
    let reply = try LockDeliveryReply(delivery: command, result: ActionResult(id: command.id, outcome: .unknown))
    #expect(throws: WireError.invalidPayload) { try reply.validate(for: delivery()) }
}
