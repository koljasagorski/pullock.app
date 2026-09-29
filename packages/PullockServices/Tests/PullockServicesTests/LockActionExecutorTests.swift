import Foundation
import PullockCore
@testable import PullockServices
import Testing

@Test @MainActor func lockExecutorDeduplicatesAcrossReconnectAndRejectsOldEpochs() throws {
    var calls = 0
    let executor = LockActionExecutor { _ in calls += 1; return .unknown }
    let boot = UUID()
    try executor.bind(boot: boot)
    let id = ActionID(trigger: TriggerID(boot: boot, arming: 2), kind: .lock, cause: .removal)
    let first = try executor.execute(id)
    try executor.bind(boot: boot)
    #expect(try executor.execute(id) == first && calls == 1)
    #expect(throws: LockExecutorError.staleArming) {
        try executor.execute(ActionID(trigger: TriggerID(boot: boot, arming: 1), kind: .lock, cause: .removal))
    }
    try executor.bind(boot: UUID())
    #expect(throws: LockExecutorError.wrongBoot) { try executor.bind(boot: boot) }
    #expect(throws: LockExecutorError.wrongBoot) { try executor.execute(id) }
}

@Test @MainActor func lockExecutorDoesNotReplayFailedOrInvalidOperations() throws {
    var calls = 0
    let executor = LockActionExecutor { _ in calls += 1; throw LockExecutorError.invalidResult }
    let boot = UUID(); try executor.bind(boot: boot)
    let id = ActionID(trigger: TriggerID(boot: boot, arming: 1), kind: .lock, cause: .removal)
    #expect(try executor.execute(id).outcome == .failed)
    #expect(try executor.execute(id).outcome == .failed && calls == 1)
    let invalid = LockActionExecutor { _ in .confirmed }
    try invalid.bind(boot: boot)
    #expect(throws: LockExecutorError.invalidResult) { try invalid.execute(id) }
    #expect(try invalid.execute(id).outcome == .failed)
}
