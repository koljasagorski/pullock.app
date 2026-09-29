import Foundation

public enum ProtectionStatus: String, Codable, Sendable {
    case disarmed, waiting, armed, triggered, error
}

public enum ExecutionProfile: String, Codable, Sendable { case live, simulation }
public enum ActionQualification: String, Sendable { case unavailable, mockOnly, qualified }

/// Supplied by the trusted host at construction, never a user command or preference.
public struct RuntimeCapabilities: Sendable {
    public let profile: ExecutionProfile
    public let lock: ActionQualification
    public let shutdown: ActionQualification

    public init(profile: ExecutionProfile = .live, lock: ActionQualification = .unavailable,
                shutdown: ActionQualification = .unavailable) {
        self.profile = profile
        self.lock = lock
        self.shutdown = shutdown
    }

    public func permits(_ qualification: ActionQualification) -> Bool {
        qualification == .qualified || (profile == .simulation && qualification == .mockOnly)
    }
}

public enum HealthComponent: String, CaseIterable, Codable, Sendable {
    case app, agent, daemon, watcher, ipc, policy, identity, lockPath, shutdownPath
}

public enum HealthCondition: String, Codable, Sendable { case healthy, unavailable, failed }

public struct HealthObservation: Equatable, Sendable {
    public let component: HealthComponent
    public let generation: UInt64
    public let progress: UInt64
    public let condition: HealthCondition

    public init(_ component: HealthComponent, generation: UInt64, progress: UInt64,
                condition: HealthCondition = .healthy) {
        self.component = component
        self.generation = generation
        self.progress = progress
        self.condition = condition
    }
}

public enum PowerPhase: String, Codable, Sendable { case awake, sleeping, waking }
public enum SessionCondition: String, Codable, Sendable { case activeOwner, inactive, unknown }

public struct ObservationEpoch: Equatable, Codable, Sendable {
    public let watcher: UInt64
    public let power: UInt64
    public let arming: UInt64

    public init(watcher: UInt64, power: UInt64, arming: UInt64) {
        self.watcher = watcher
        self.power = power
        self.arming = arming
    }
}

public struct TriggerID: Equatable, Hashable, Codable, Sendable {
    public let boot: UUID
    public let arming: UInt64

    public init(boot: UUID, arming: UInt64) { self.boot = boot; self.arming = arming }
}

public enum ActionKind: String, Codable, Sendable { case lock, shutdown }
public enum ActionCause: String, Codable, Sendable { case removal, healthFailure, sessionBoundary, wakeWithoutKey }
public enum ActionOutcome: String, Codable, Sendable {
    case submitted, confirmed, failed, unknown, simulated
    public var isTerminal: Bool { self != .submitted }
}

public struct ActionID: Equatable, Hashable, Codable, Sendable {
    public let trigger: TriggerID
    public let kind: ActionKind
    public let cause: ActionCause

    public init(trigger: TriggerID, kind: ActionKind, cause: ActionCause) {
        self.trigger = trigger; self.kind = kind; self.cause = cause
    }
}

public struct ActionRequest: Equatable, Codable, Sendable {
    public let id: ActionID
    public let profile: ExecutionProfile

    public init(id: ActionID, profile: ExecutionProfile) { self.id = id; self.profile = profile }
}

public struct ActionResult: Equatable, Codable, Sendable {
    public let id: ActionID
    public let outcome: ActionOutcome

    public init(id: ActionID, outcome: ActionOutcome) { self.id = id; self.outcome = outcome }
}

public enum Effect: Equatable, Sendable {
    case requestInventory(ObservationEpoch)
    case action(ActionRequest)
}

public enum StateIssue: Equatable, Codable, Sendable {
    case missingHealth(HealthComponent), staleHealth(HealthComponent), unhealthy(HealthComponent)
    case lockUnqualified, shutdownUnqualified, shutdownNotAcknowledged
    case duplicateIdentity, unknownProduct, invalidDevice, inventoryMismatch, inventoryOverflow
    case watcherRestarted, sessionChanged, recoveryRequired, monotonicClockFailure
}

public struct StateSnapshot: Equatable, Codable, Sendable {
    public let bootID: UUID
    public let revision: UInt64
    public let generatedAt: UInt64
    public let validUntil: UInt64
    public let profile: ExecutionProfile
    public let status: ProtectionStatus
    public let policyRevision: UInt64?
    public let mode: ActionMode
    public let armIntent: Bool
    public let seenKeySinceArming: Bool
    public let epoch: ObservationEpoch
    public let healthGeneration: UInt64
    public let power: PowerPhase
    public let session: SessionCondition
    public let matchingDeviceCount: Int
    public let issues: [StateIssue]
    public let trigger: TriggerID?
    public let lockOutcome: ActionOutcome?
    public let shutdownOutcome: ActionOutcome?

    public var hasArmedInvariants: Bool {
        armIntent && seenKeySinceArming && matchingDeviceCount == 1 && issues.isEmpty
            && power == .awake && session == .activeOwner && trigger == nil
            && lockOutcome == nil && shutdownOutcome == nil
            && (policyRevision ?? 0) > 0 && epoch.arming > 0
    }

    /// Call at display time. A stored ARMED value cannot make an expired lease green.
    public func isProtected(at now: UInt64) -> Bool {
        profile == .live && status == .armed && hasArmedInvariants
            && generatedAt <= now && now < validUntil
    }

    public func displayStatus(at now: UInt64) -> ProtectionStatus {
        guard generatedAt <= now, now < validUntil else { return .error }
        if status == .armed && !hasArmedInvariants { return .error }
        return status
    }
}

public protocol HealthClock: Sendable {
    var now: UInt64 { get }
}
