import Foundation

/// Synchronous, deterministic authority. Effects are values; this target has no
/// IOKit, AppKit, IPC, filesystem, process execution, lock or shutdown adapter.
public struct ProtectionReducer: Sendable {
    public let bootID: UUID
    public let capabilities: RuntimeCapabilities
    public let healthLeaseMilliseconds: UInt64
    private var policy: ProtectionPolicy?
    private var revision: UInt64 = 0
    private var now: UInt64 = 0
    private var sequences: [EventSource: UInt64] = [:]
    private var timestamps: [EventSource: UInt64] = [:]
    private var watcherEpoch: UInt64 = 1
    private var powerEpoch: UInt64 = 0
    private var armingEpoch: UInt64 = 0
    private var healthGeneration: UInt64 = 1
    private var health: [HealthComponent: Lease] = [:]
    private var devices: [UInt64: DeviceObservation] = [:]
    private var bound: DeviceObservation?
    private var seen = false
    private var armIntent = false
    private var awaitingInventory = false
    private var recoveryRequired = false
    private var fallbackRequested = false
    private var resumeAfterSleep = false
    private var selectionExpired = false
    private var power: PowerPhase = .awake
    private var session: SessionCondition = .unknown
    private var status: ProtectionStatus = .error
    private var faults: [StateIssue] = []
    private var trigger: TriggerID?
    private var requestedActions: Set<ActionID> = []
    private var results: [ActionID: ActionOutcome] = [:]

    private struct Lease: Sendable {
        let observation: HealthObservation
        let observedAt: UInt64
    }

    public init(bootID: UUID, capabilities: RuntimeCapabilities = .init(),
                healthLeaseMilliseconds: UInt64 = 3_000) throws {
        guard (100...60_000).contains(healthLeaseMilliseconds) else { throw ValidationError.invalidLease }
        self.bootID = bootID
        self.capabilities = capabilities
        self.healthLeaseMilliseconds = healthLeaseMilliseconds
    }

    public var snapshot: StateSnapshot {
        let mode = policy?.mode ?? .lock
        let lockID = trigger.map { ActionID(trigger: $0, kind: .lock, cause: .removal) }
        let shutdownID = trigger.map { ActionID(trigger: $0, kind: .shutdown, cause: .removal) }
        return StateSnapshot(
            bootID: bootID, revision: revision, generatedAt: now, validUntil: deadline,
            profile: capabilities.profile, status: status, policyRevision: policy?.revision, mode: mode,
            armIntent: armIntent, seenKeySinceArming: seen, epoch: epoch,
            healthGeneration: healthGeneration, power: power, session: session,
            matchingDeviceCount: matching.count, issues: issues,
            trigger: trigger, lockOutcome: lockID.flatMap { results[$0] },
            shutdownOutcome: shutdownID.flatMap { results[$0] }
        )
    }

    /// One call is one serialized transaction. The caller dispatches returned
    /// effects after commit, without awaiting lock completion before shutdown.
    public mutating func process(_ envelope: EventEnvelope, at instant: UInt64) -> Transition {
        var effects: [Effect] = []
        guard instant >= now else {
            addFault(.monotonicClockFailure)
            if armIntent { recoveryRequired = true }
            refresh(effects: &effects)
            revision += 1
            return Transition(snapshot: snapshot, effects: effects, rejection: .staleTimestamp)
        }
        now = instant
        // Even rejected traffic cannot keep an expired snapshot alive.
        refresh(effects: &effects)
        let rejection: EventRejection?
        if envelope.bootID != bootID { rejection = .wrongBoot }
        else if envelope.source != envelope.event.source { rejection = .wrongSource }
        else if envelope.sequence == 0 || envelope.sequence <= sequences[envelope.source, default: 0] {
            rejection = .staleSequence
        } else if envelope.observedAt > now { rejection = .futureEvent }
        else if envelope.observedAt < timestamps[envelope.source, default: 0] { rejection = .staleTimestamp }
        else {
            sequences[envelope.source] = envelope.sequence
            timestamps[envelope.source] = envelope.observedAt
            rejection = apply(envelope.event, observedAt: envelope.observedAt, effects: &effects)
        }
        refresh(effects: &effects)
        revision += 1
        return Transition(snapshot: snapshot, effects: effects, rejection: rejection)
    }

    private var epoch: ObservationEpoch {
        ObservationEpoch(watcher: watcherEpoch, power: powerEpoch, arming: armingEpoch)
    }

    private var requiredHealth: [HealthComponent] {
        HealthComponent.allCases.filter { $0 != .shutdownPath || policy?.mode == .lockAndShutdown }
    }

    private var healthIssues: [StateIssue] {
        requiredHealth.compactMap { component in
            guard let lease = health[component] else { return .missingHealth(component) }
            guard lease.observation.condition == .healthy else { return .unhealthy(component) }
            guard lease.observedAt <= now, now - lease.observedAt < healthLeaseMilliseconds else {
                return .staleHealth(component)
            }
            return nil
        }
    }

    private var matching: [DeviceObservation] {
        guard let policy else { return [] }
        if policy.enrollment.connection != nil && selectionExpired { return [] }
        return devices.values.filter(policy.enrollment.matches)
    }

    private var identityIssues: [StateIssue] {
        guard let policy else { return [] }
        let claims = devices.values.filter(policy.enrollment.claimsIdentity)
        var reasons: [StateIssue] = []
        if policy.enrollment.connection != nil && selectionExpired { reasons.append(.selectionExpired) }
        if claims.count > 1 { reasons.append(.duplicateIdentity) }
        if claims.contains(where: { !policy.enrollment.acceptedProductIDs.contains($0.productID) }) {
            reasons.append(.unknownProduct)
        }
        return reasons
    }

    private var issues: [StateIssue] {
        var reasons = faults + healthIssues + identityIssues
        if !capabilities.permits(capabilities.lock) { reasons.append(.lockUnqualified) }
        if policy?.mode == .lockAndShutdown {
            if !capabilities.permits(capabilities.shutdown) { reasons.append(.shutdownUnqualified) }
            if policy?.shutdownAcknowledged != true { reasons.append(.shutdownNotAcknowledged) }
        }
        if recoveryRequired { reasons.append(.recoveryRequired) }
        return reasons
    }

    private var deadline: UInt64 {
        func addingLease(_ time: UInt64) -> UInt64 {
            let (value, overflow) = time.addingReportingOverflow(healthLeaseMilliseconds)
            return overflow ? UInt64.max : value
        }
        return requiredHealth.compactMap { health[$0].map { addingLease($0.observedAt) } }
            .reduce(addingLease(now), min)
    }

    private mutating func apply(_ event: ProtectionEvent, observedAt: UInt64,
                                effects: inout [Effect]) -> EventRejection? {
        switch event {
        case let .configure(candidate, expectedRevision):
            guard !armIntent, bound == nil, trigger == nil else { return .notDisarmed }
            guard expectedRevision == policy?.revision else { return .revisionConflict }
            let previous = policy?.revision ?? 0
            guard previous < UInt64.max, candidate.revision == previous + 1 else { return .revisionConflict }
            do { try candidate.validate() } catch { return .invalidPolicy }
            if let connection = candidate.enrollment.connection {
                guard connection.bootID == bootID, connection.watcher == watcherEpoch,
                      connection.power == powerEpoch, power == .awake, session == .activeOwner,
                      devices.values.contains(where: candidate.enrollment.matches) else { return .invalidPolicy }
            }
            policy = candidate
            selectionExpired = false
        case let .arm(expectedRevision):
            guard trigger == nil else { return .triggerLatched }
            guard let policy else { return .noPolicy }
            guard policy.revision == expectedRevision else { return .revisionConflict }
            guard !armIntent || recoveryRequired else { return .alreadyArmed }
            guard session == .activeOwner else { return .inactiveSession }
            if let connection = policy.enrollment.connection {
                guard !selectionExpired, connection.bootID == bootID, connection.watcher == watcherEpoch,
                      connection.power == powerEpoch, power == .awake else { return .invalidPolicy }
            }
            armingEpoch += 1
            armIntent = true
            clearPresence()
            recoveryRequired = false
            fallbackRequested = false
            resumeAfterSleep = false
            faults.removeAll()
            requestedActions.removeAll()
            results.removeAll()
            awaitingInventory = true
            if power == .awake { effects.append(.requestInventory(epoch)) }
        case let .disarm(expectedArming):
            guard trigger == nil else { return .triggerLatched }
            guard expectedArming == armingEpoch else { return .staleEpoch }
            armingEpoch += 1
            armIntent = false
            recoveryRequired = false
            resumeAfterSleep = false
            clearPresence()
            faults.removeAll()
        case let .resetTrigger(id):
            guard trigger == id else { return .staleEpoch }
            guard session == .activeOwner else { return .inactiveSession }
            let lockID = ActionID(trigger: id, kind: .lock, cause: .removal)
            guard results[lockID]?.isTerminal == true else { return .actionNotComplete }
            let shutdownID = ActionID(trigger: id, kind: .shutdown, cause: .removal)
            if requestedActions.contains(shutdownID), results[shutdownID]?.isTerminal != true {
                return .actionNotComplete
            }
            trigger = nil
            armIntent = false
            armingEpoch += 1
            clearPresence()
            recoveryRequired = false
            resumeAfterSleep = false
            faults.removeAll()
            requestedActions.removeAll()
            results.removeAll()
        case let .inventory(observations, incomingEpoch):
            guard incomingEpoch == epoch else { return .staleEpoch }
            guard power == .awake else { return .invalidPowerTransition }
            guard observations.count <= 128 else { fail(.inventoryOverflow); return nil }
            guard observations.allSatisfy(\.isValid), Set(observations.map(\.instance)).count == observations.count else {
                fail(.invalidDevice); return nil
            }
            let inventory = Dictionary(uniqueKeysWithValues: observations.map { ($0.instance, $0) })
            if let enrollment = policy?.enrollment, enrollment.connection != nil,
               !inventory.values.contains(where: enrollment.matches) { selectionExpired = true }
            if let bound, inventory[bound.instance] != bound { fail(.inventoryMismatch) }
            devices = inventory
            awaitingInventory = false
            if resumeAfterSleep && matching.isEmpty {
                requestFallback(.wakeWithoutKey, effects: &effects)
                resumeAfterSleep = false
            }
        case let .attached(device, incomingEpoch):
            guard incomingEpoch == epoch else { return .staleEpoch }
            guard power == .awake else { return .invalidPowerTransition }
            guard device.isValid else { fail(.invalidDevice); return nil }
            if let previous = devices[device.instance], previous != device { fail(.invalidDevice); return nil }
            guard devices[device.instance] != nil || devices.count < 128 else { fail(.inventoryOverflow); return nil }
            devices[device.instance] = device
            // A fresh matching snapshot, not an arbitrary attach, completes an ARM request.
        case let .removed(instance, incomingEpoch):
            guard incomingEpoch == epoch else { return .staleEpoch }
            devices.removeValue(forKey: instance)
            if policy?.enrollment.connection?.instance == instance { selectionExpired = true }
            if trigger == nil, armIntent, seen, bound?.instance == instance,
               power == .awake, session == .activeOwner {
                let id = TriggerID(boot: bootID, arming: armingEpoch)
                trigger = id
                request(.lock, cause: .removal, trigger: id, effects: &effects)
                if policy?.mode == .lockAndShutdown {
                    request(.shutdown, cause: .removal, trigger: id, effects: &effects)
                }
            }
        case .willSleep:
            guard power == .awake else { return .invalidPowerTransition }
            resumeAfterSleep = armIntent && seen
            if policy?.enrollment.connection != nil { selectionExpired = true }
            power = .sleeping
            powerEpoch += 1
            clearPresence()
            invalidateHealth()
        case .willWake:
            guard power == .sleeping else { return .invalidPowerTransition }
            power = .waking
        case .didWake:
            guard power == .sleeping || power == .waking else { return .invalidPowerTransition }
            power = .awake
            awaitingInventory = true
            effects.append(.requestInventory(epoch))
        case .displaySleep: break
        case let .session(condition):
            guard condition != session else { break }
            if armIntent && seen { requestFallback(.sessionBoundary, effects: &effects) }
            if armIntent { fail(.sessionChanged) }
            if policy?.enrollment.connection != nil { selectionExpired = true }
            session = condition
            armingEpoch += 1
            clearPresence()
            invalidateHealth()
        case let .health(observation):
            guard observation.generation == healthGeneration else { return .staleHealthGeneration }
            let previousProgress = health[observation.component]?.observation.progress ?? 0
            guard observation.progress >= previousProgress else { return .noProgress }
            if observation.condition == .healthy {
                guard observation.progress > previousProgress else {
                    return .noProgress
                }
            }
            health[observation.component] = Lease(observation: observation, observedAt: observedAt)
        case let .actionResult(result):
            guard requestedActions.contains(result.id) else { return .invalidActionResult }
            guard result.outcome != .simulated || capabilities.profile == .simulation else { return .invalidActionResult }
            guard results[result.id]?.isTerminal != true else { return .invalidActionResult }
            results[result.id] = result.outcome
        case .watcherRestarted:
            if policy?.enrollment.connection != nil { selectionExpired = true }
            if armIntent && seen { requestFallback(.healthFailure, effects: &effects) }
            if armIntent { fail(.watcherRestarted) }
            watcherEpoch += 1
            clearPresence()
            invalidateHealth()
        case .tick: break
        }
        return nil
    }

    private mutating func refresh(effects: inout [Effect]) {
        if trigger != nil { status = .triggered; return }
        let reasons = issues
        if armIntent && !identityIssues.isEmpty { recoveryRequired = true }
        if armIntent, seen, !reasons.isEmpty {
            recoveryRequired = true
            requestFallback(.healthFailure, effects: &effects)
        }
        if recoveryRequired || !faults.isEmpty || !identityIssues.isEmpty {
            status = .error
            return
        }
        if power != .awake {
            status = armIntent ? .waiting : .disarmed
            return
        }
        guard reasons.isEmpty else { status = .error; return }
        if session != .activeOwner {
            status = armIntent ? .waiting : .disarmed
            return
        }
        guard armIntent else { status = .disarmed; return }
        guard !awaitingInventory else { status = .waiting; return }
        if bound == nil, matching.count == 1 {
            bound = matching[0]
            seen = true
            resumeAfterSleep = false
        }
        status = bound == nil ? .waiting : .armed
    }

    private mutating func clearPresence() {
        bound = nil
        seen = false
        devices.removeAll()
        awaitingInventory = false
    }

    private mutating func invalidateHealth() {
        healthGeneration += 1
        health.removeAll()
    }

    private mutating func fail(_ issue: StateIssue) {
        addFault(issue)
        if armIntent { recoveryRequired = true }
    }

    private mutating func addFault(_ issue: StateIssue) {
        if !faults.contains(issue) { faults.append(issue) }
    }

    private mutating func requestFallback(_ cause: ActionCause, effects: inout [Effect]) {
        guard !fallbackRequested, capabilities.permits(capabilities.lock) else { return }
        fallbackRequested = true
        request(.lock, cause: cause, trigger: TriggerID(boot: bootID, arming: armingEpoch), effects: &effects)
    }

    private mutating func request(_ kind: ActionKind, cause: ActionCause, trigger: TriggerID,
                                 effects: inout [Effect]) {
        let id = ActionID(trigger: trigger, kind: kind, cause: cause)
        guard requestedActions.insert(id).inserted else { return }
        effects.append(.action(ActionRequest(id: id, profile: capabilities.profile)))
    }
}
