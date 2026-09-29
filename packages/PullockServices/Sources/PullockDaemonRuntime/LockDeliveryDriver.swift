import Foundation
import PullockCore
import PullockIPC
import PullockServices

/// Bounded dispatcher. It never retries an uncertain keyboard submission.
/// The executor at the destination independently deduplicates ActionIDs.
@MainActor
final class LockDeliveryDriver {
    typealias Delivery = @MainActor (ActionRequest, OwnerSessionPolicy) async throws -> ActionResult
    private let deliver: Delivery
    private let completed: @MainActor (ActionResult, OwnerSessionPolicy) -> Void
    private var pending: [ActionID: Task<Void, Never>] = [:]
    private var stopped = false

    init(deliver: @escaping Delivery,
         completed: @escaping @MainActor (ActionResult, OwnerSessionPolicy) -> Void) {
        self.deliver = deliver; self.completed = completed
    }

    func submit(_ request: ActionRequest, owner: OwnerSessionPolicy) {
        guard !stopped, request.profile == .live, request.id.kind == .lock,
              pending[request.id] == nil else { return }
        guard pending.count < 8 else {
            completed(ActionResult(id: request.id, outcome: .failed), owner); return
        }
        pending[request.id] = Task { [weak self] in
            guard let self, !self.stopped, !Task.isCancelled else { return }
            let result: ActionResult
            do {
                let response = try await deliver(request, owner)
                guard response.id == request.id, response.outcome == .unknown || response.outcome == .failed else {
                    throw LockTransportError.invalidReply
                }
                result = response
            } catch { result = ActionResult(id: request.id, outcome: .unknown) }
            pending[request.id] = nil
            guard !stopped, !Task.isCancelled else { return }
            completed(result, owner)
        }
    }

    func stop() {
        stopped = true
        for task in pending.values { task.cancel() }
        pending.removeAll()
    }
}
