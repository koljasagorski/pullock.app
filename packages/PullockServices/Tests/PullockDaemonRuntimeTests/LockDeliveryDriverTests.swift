import Foundation
import PullockCore
import PullockIPC
import PullockServices
@testable import PullockDaemonRuntime
import Testing

@Test @MainActor func stoppingBeforeDispatchPreventsAnyDelivery() async throws {
    var calls = 0
    var completions = 0
    let driver = LockDeliveryDriver(deliver: { request, _ in
        calls += 1
        return ActionResult(id: request.id, outcome: .unknown)
    }, completed: { _, _ in completions += 1 })
    let owner = try OwnerSessionPolicy(uid: 501, auditSession: 42, active: true)
    let request = ActionRequest(id: ActionID(trigger: TriggerID(boot: UUID(), arming: 1),
        kind: .lock, cause: .removal), profile: .live)
    driver.submit(request, owner: owner)
    driver.stop()
    // This test owns MainActor until the stop has completed. The newly queued
    // task can only begin once this turn yields, so cancellation wins admission.
    for _ in 0..<100 { await Task.yield() }
    #expect(calls == 0 && completions == 0)
}

@Test @MainActor func deliveryFailureIsUncertainAndNeverRetried() async throws {
    var calls = 0
    var results: [ActionResult] = []
    let driver = LockDeliveryDriver(deliver: { _, _ in calls += 1; throw LockTransportError.timeout },
        completed: { result, _ in results.append(result) })
    let owner = try OwnerSessionPolicy(uid: 501, auditSession: 42, active: true)
    let request = ActionRequest(id: ActionID(trigger: TriggerID(boot: UUID(), arming: 1), kind: .lock, cause: .removal), profile: .live)
    driver.submit(request, owner: owner); driver.submit(request, owner: owner)
    for _ in 0..<100 where results.isEmpty { await Task.yield() }
    #expect(calls == 1 && results == [ActionResult(id: request.id, outcome: .unknown)])
    driver.stop()
    driver.submit(request, owner: owner)
    #expect(calls == 1)
}

@Test @MainActor func deliveryCannotReportConfirmedSuccessOrWrongAction() async throws {
    var results: [ActionResult] = []
    let driver = LockDeliveryDriver(deliver: { request, _ in ActionResult(id: request.id, outcome: .confirmed) },
        completed: { result, _ in results.append(result) })
    let owner = try OwnerSessionPolicy(uid: 501, auditSession: 42, active: true)
    let request = ActionRequest(id: ActionID(trigger: TriggerID(boot: UUID(), arming: 1), kind: .lock, cause: .removal), profile: .live)
    driver.submit(request, owner: owner)
    for _ in 0..<100 where results.isEmpty { await Task.yield() }
    #expect(results == [ActionResult(id: request.id, outcome: .unknown)])
}
