import Foundation

public enum EventSource: String, Hashable, Sendable { case user, usb, power, session, health, action, lifecycle, clock }

public enum ProtectionEvent: Sendable {
    case configure(ProtectionPolicy, expectedRevision: UInt64?)
    case arm(expectedRevision: UInt64)
    case disarm(expectedArming: UInt64)
    case resetTrigger(TriggerID)
    case inventory([DeviceObservation], ObservationEpoch)
    case attached(DeviceObservation, ObservationEpoch)
    case removed(instance: UInt64, epoch: ObservationEpoch)
    case willSleep
    case willWake
    case didWake
    case displaySleep
    case session(SessionCondition)
    case health(HealthObservation)
    case actionResult(ActionResult)
    case watcherRestarted
    case tick

    public var source: EventSource {
        switch self {
        case .configure, .arm, .disarm, .resetTrigger: .user
        case .inventory, .attached, .removed: .usb
        case .willSleep, .willWake, .didWake, .displaySleep: .power
        case .session: .session
        case .health: .health
        case .actionResult: .action
        case .watcherRestarted: .lifecycle
        case .tick: .clock
        }
    }
}

/// Constructed by the authoritative host after transport validation, not trusted
/// because it happens to decode. Units are monotonic milliseconds since host boot.
public struct EventEnvelope: Sendable {
    public let bootID: UUID
    public let source: EventSource
    public let sequence: UInt64
    public let observedAt: UInt64
    public let event: ProtectionEvent

    public init(bootID: UUID, source: EventSource, sequence: UInt64, observedAt: UInt64,
                event: ProtectionEvent) {
        self.bootID = bootID; self.source = source; self.sequence = sequence
        self.observedAt = observedAt; self.event = event
    }
}

public enum EventRejection: String, Codable, Sendable {
    case wrongBoot, wrongSource, staleSequence, futureEvent, staleTimestamp, staleEpoch
    case staleHealthGeneration, noProgress, revisionConflict, invalidPolicy, notDisarmed
    case noPolicy, alreadyArmed, triggerLatched, actionNotComplete, inactiveSession
    case invalidActionResult, invalidPowerTransition, recoveryRequiresArm
}

public struct Transition: Sendable {
    public let snapshot: StateSnapshot
    public let effects: [Effect]
    public let rejection: EventRejection?

    public var accepted: Bool { rejection == nil }
}
