import Foundation
import PullockCore
import PullockIPC
import Synchronization

public enum AuthorityError: String, Error, Sendable {
    case rejected, unauthorized, staleOwner, unavailable, invalidInventory
}

/// A synchronous host boundary for the reducer. Transport authentication stays
/// outside this type; only a trusted daemon host may create it or supply events.
/// The default live capabilities forbid every real action. This host has no
/// filesystem, device command, process execution or input-event capability.
public final class ProtectionAuthority: Sendable {
    public let bootID: UUID
    private struct State {
        var core: ProtectionReducer
        var sequences: [EventSource: UInt64] = [:]
        var progress: [HealthComponent: UInt64] = [:]
        var inventory: [WireDevice] = []
        var watcherReady = false
        var owner: OwnerSessionPolicy?
        var effects: [Effect] = []
        var overloaded = false
    }
    private let state: Mutex<State>

    public init(capabilities: RuntimeCapabilities = .init()) throws {
        let boot = UUID()
        bootID = boot
        state = Mutex(State(core: try ProtectionReducer(bootID: boot, capabilities: capabilities)))
    }

    /// Bound by the trusted host after OS signature, primary console and session
    /// checks. A different UID/session cannot silently replace an existing owner.
    public func bindOwner(_ owner: OwnerSessionPolicy, now: UInt64) throws {
        try state.withLock { state in
            try owner.validate(effectiveUID: owner.uid, auditSession: owner.auditSession)
            if let existing = state.owner {
                guard existing.uid == owner.uid, existing.auditSession == owner.auditSession else {
                    throw AuthorityError.staleOwner
                }
            }
            let changed = state.owner?.active != true
            state.owner = owner
            _ = send(.session(.activeOwner), state: &state, now: now)
            if changed {
                state.watcherReady = false; state.inventory = []
                state.effects.removeAll { if case .requestInventory = $0 { true } else { false } }
                state.effects.append(.requestInventory(state.core.snapshot.epoch))
            }
        }
    }

    /// Trusted lifecycle notification; invalidates selection without admitting
    /// another owner. A new daemon/session setup is required for a new owner.
    public func ownerBecameInactive(now: UInt64) {
        state.withLock { state in
            state.owner = state.owner.flatMap { try? OwnerSessionPolicy(uid: $0.uid, auditSession: $0.auditSession, active: false) }
            _ = send(.session(.inactive), state: &state, now: now)
            state.watcherReady = false; state.inventory = []
        }
    }

    public func snapshot(now: UInt64) -> StateSnapshot {
        state.withLock { state in send(.tick, state: &state, now: now).snapshot }
    }

    /// Only the watcher host supplies inventory. Raw serials are deliberately
    /// absent in this connection-selection host.
    public func inventory(_ devices: [WireDevice], epoch: ObservationEpoch, now: UInt64) throws {
        try state.withLock { state in
            guard !state.overloaded else { throw AuthorityError.unavailable }
            guard devices.count <= 128, devices.allSatisfy(\.valid),
                  Set(devices.map(\.instance)).count == devices.count else {
                state.watcherReady = false
                health(.watcher, condition: .failed, state: &state, now: now)
                throw AuthorityError.invalidInventory
            }
            let observations = devices.map { DeviceObservation(instance: $0.instance, vendorID: $0.vendorID, productID: $0.productID, serial: nil) }
            let transition = send(.inventory(observations, epoch), state: &state, now: now)
            guard transition.accepted else { throw AuthorityError.rejected }
            state.inventory = devices; state.watcherReady = !state.overloaded
            health(.watcher, state: &state, now: now)
        }
    }

    public func removed(instance: UInt64, epoch: ObservationEpoch, now: UInt64) {
        state.withLock { state in
            let transition = send(.removed(instance: instance, epoch: epoch), state: &state, now: now)
            if transition.accepted { state.inventory.removeAll { $0.instance == instance } }
        }
    }

    public func lifecycle(_ event: ProtectionEvent, now: UInt64) throws {
        try state.withLock { state in
            switch event {
            case .willSleep, .willWake, .didWake, .displaySleep, .watcherRestarted:
                let transition = send(event, state: &state, now: now)
                guard transition.accepted else { throw AuthorityError.rejected }
                if case .displaySleep = event { return }
                state.watcherReady = false; state.inventory = []
            default: throw AuthorityError.unauthorized
            }
        }
    }

    /// Progress originates from the host that actually serviced the relevant
    /// path. This API must never be directly mapped to a client-supplied enum.
    public func processed(_ component: HealthComponent, condition: HealthCondition = .healthy, now: UInt64) {
        state.withLock { health(component, condition: condition, state: &$0, now: now) }
    }

    public func command(_ payload: WirePayload, role: ProcessRole, owner: OwnerSessionPolicy, now: UInt64) throws -> WirePayload {
        try state.withLock { state in
            guard let bound = state.owner else { throw AuthorityError.unavailable }
            try bound.validate(effectiveUID: owner.uid, auditSession: owner.auditSession)
            try owner.validate(effectiveUID: bound.uid, auditSession: bound.auditSession)
            // Check role again at the authority boundary, in addition to wire
            // authorization. A trusted transport cannot accidentally widen it.
            switch payload {
            case .getHealth:
                guard role == .app || role == .sessionAgent else { throw AuthorityError.unauthorized }
            case .getDevices, .configure, .arm, .disarm, .resetTrigger:
                guard role == .app else { throw AuthorityError.unauthorized }
            case .sessionHeartbeat, .lockResult:
                guard role == .sessionAgent else { throw AuthorityError.unauthorized }
            default: throw AuthorityError.unauthorized
            }
            health(.ipc, state: &state, now: now)
            if role == .app { health(.app, state: &state, now: now) }
            let event: ProtectionEvent?
            switch payload {
            case .getHealth: event = nil
            case .getDevices:
                guard state.watcherReady else { throw AuthorityError.unavailable }
                return .devices(inventory: state.inventory, state: send(.tick, state: &state, now: now).snapshot)
            case let .configure(policy, expectedRevision):
                guard policy.enrollment.connection != nil, policy.mode == .lock,
                      !policy.shutdownAcknowledged, state.watcherReady else { throw AuthorityError.rejected }
                event = .configure(policy, expectedRevision: expectedRevision)
            case let .arm(expectedRevision):
                guard state.watcherReady, !state.overloaded, state.effects.count < 64 else {
                    throw AuthorityError.unavailable
                }
                event = .arm(expectedRevision: expectedRevision)
            case let .disarm(expectedArming): event = .disarm(expectedArming: expectedArming)
            case let .resetTrigger(id): event = .resetTrigger(id)
            case let .sessionHeartbeat(generation, progress):
                event = .health(HealthObservation(.agent, generation: generation, progress: progress))
            case let .lockResult(result):
                // The public shortcut cannot report confirmed lock success.
                guard result.outcome == .unknown || result.outcome == .failed else { throw AuthorityError.rejected }
                event = .actionResult(result)
            default: throw AuthorityError.unauthorized
            }
            if let event {
                let transition = send(event, state: &state, now: now)
                guard transition.accepted else { throw AuthorityError.rejected }
            }
            return .snapshot(state: send(.tick, state: &state, now: now).snapshot)
        }
    }

    /// The host dispatches effects after the transaction, without blocking the
    /// reducer on IPC. Retries need ActionID deduplication in the action agent.
    public func takeEffects() -> [Effect] {
        state.withLock { state in
            let effects = state.effects; state.effects.removeAll(); return effects
        }
    }

    @discardableResult private func send(_ event: ProtectionEvent, state: inout State, now: UInt64) -> Transition {
        let next = state.sequences[event.source, default: 0].addingReportingOverflow(1)
        state.sequences[event.source] = next.overflow ? UInt64.max : next.partialValue
        let transition = state.core.process(EventEnvelope(bootID: bootID, source: event.source,
            sequence: state.sequences[event.source]!, observedAt: now, event: event), at: now)
        // Inventory requests are replaceable by the newest epoch. Actions are
        // retained individually. Stop admitting new arming cycles well before
        // the bounded action queue fills; never discard an action to stay green.
        for effect in transition.effects {
            if case .requestInventory = effect {
                state.effects.removeAll { if case .requestInventory = $0 { true } else { false } }
            }
            state.effects.append(effect)
        }
        if state.effects.count >= 64, !state.overloaded {
            state.overloaded = true; state.watcherReady = false
            health(.watcher, condition: .failed, state: &state, now: now)
        }
        return transition
    }

    private func health(_ component: HealthComponent, condition: HealthCondition = .healthy, state: inout State, now: UInt64) {
        let next = state.progress[component, default: 0].addingReportingOverflow(1)
        state.progress[component] = next.overflow ? UInt64.max : next.partialValue
        _ = send(.health(HealthObservation(component, generation: state.core.snapshot.healthGeneration,
            progress: state.progress[component]!, condition: component == .watcher && state.overloaded ? .failed : condition)), state: &state, now: now)
    }
}
