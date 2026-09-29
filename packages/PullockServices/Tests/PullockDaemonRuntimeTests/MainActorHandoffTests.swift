import Foundation
import PullockIPC
@testable import PullockDaemonRuntime
import Synchronization
import Testing

@Test @MainActor func cancelledHandoffsRemainBoundedAndCannotLaterChangeState() throws {
    let queue = Mutex<[@MainActor @Sendable () -> Void]>([])
    let calls = Mutex(0)
    let handoff = MainActorHandoff(timeoutMilliseconds: 1, enqueue: { work in queue.withLock { $0.append(work) } })
    for _ in 0..<8 {
        #expect(throws: HandoffError.timeout) {
            try handoff.perform { calls.withLock { $0 += 1 }; return .getHealth }
        }
    }
    #expect(throws: HandoffError.overloaded) { try handoff.perform { .getHealth } }
    #expect(queue.withLock { $0.count } == 8)
    let work = queue.withLock { let work = $0; $0.removeAll(); return work }
    for callback in work { callback() }
    #expect(calls.withLock { $0 } == 0)
    // Draining cancelled work releases the bounded admission slots.
    #expect(throws: HandoffError.timeout) { try handoff.perform { .getHealth } }
    for callback in queue.withLock({ $0 }) { callback() }
}

@Test func handoffReturnsTheActualMainActorResult() async throws {
    let handoff = MainActorHandoff()
    let result = try await Task.detached {
        try handoff.perform {
            #expect(Thread.isMainThread)
            return .hello(role: .daemon)
        }
    }.value
    #expect(result == .hello(role: .daemon))
}
