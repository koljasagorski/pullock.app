import Foundation
import PullockIPC
import Synchronization

enum HandoffError: Error { case overloaded, timeout }

/// Bound both waiting XPC threads and enqueued main-actor work. Timed-out
/// tickets retain their slot until dequeued, so reconnects cannot accumulate
/// unlimited callbacks behind a frozen event loop. Cancelled work never starts.
final class MainActorHandoff: Sendable {
    typealias Work = @MainActor @Sendable () throws -> WirePayload
    typealias Enqueue = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    private let pending = Mutex(0)
    private let timeoutMilliseconds: Int
    private let enqueue: Enqueue

    init(timeoutMilliseconds: Int = 900, enqueue: @escaping Enqueue = { work in
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }) {
        self.timeoutMilliseconds = timeoutMilliseconds; self.enqueue = enqueue
    }

    func perform(_ work: @escaping Work) throws -> WirePayload {
        let admitted = pending.withLock { count in
            guard count < 8 else { return false }
            count += 1; return true
        }
        guard admitted else { throw HandoffError.overloaded }
        let ticket = Ticket()
        enqueue { [self] in
            defer { pending.withLock { $0 -= 1 } }
            guard ticket.begin() else { return }
            ticket.finish(Result { try work() })
        }
        _ = ticket.semaphore.wait(timeout: .now() + .milliseconds(timeoutMilliseconds))
        return try ticket.resultOrCancel().get()
    }
}

private final class Ticket: Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private struct State {
        var cancelled = false
        var result: Result<WirePayload, any Error>?
    }
    private let state = Mutex(State())
    func begin() -> Bool { state.withLock { !$0.cancelled } }
    func finish(_ result: Result<WirePayload, any Error>) {
        state.withLock { $0.result = result }
        semaphore.signal()
    }
    func resultOrCancel() -> Result<WirePayload, any Error> {
        state.withLock { state in
            if let result = state.result { return result }
            state.cancelled = true
            return .failure(HandoffError.timeout)
        }
    }
}
