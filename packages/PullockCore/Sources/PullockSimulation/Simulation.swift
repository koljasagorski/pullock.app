import Foundation
import PullockCore

/// This module is linked only by development UI/tests, never the daemon target.
public struct MockProtectionActions: Sendable {
    public private(set) var requests: [ActionRequest] = []
    private var completed: [ActionID: ActionResult] = [:]

    public init() {}

    public mutating func submit(_ request: ActionRequest) -> ActionResult {
        if let result = completed[request.id] { return result }
        requests.append(request)
        let result = ActionResult(id: request.id, outcome: .simulated)
        completed[request.id] = result
        return result
    }
}

public struct ManualClock: HealthClock {
    public var now: UInt64
    public init(now: UInt64 = 0) { self.now = now }
}

public enum SimulationScenario: String, CaseIterable, Identifiable, Sendable {
    case removal, startupWithoutKey, reconnect, staleHealth, sleepWithoutKey, disarmFirst
    public var id: Self { self }
    public var title: String {
        switch self {
        case .removal: "Key removal"
        case .startupWithoutKey: "Start without a key"
        case .reconnect: "Reconnect after removal"
        case .staleHealth: "Heartbeat expires"
        case .sleepWithoutKey: "Wake without the key"
        case .disarmFirst: "Disarm before removal"
        }
    }
}

public struct SimulationStep: Sendable {
    public let label: String
    public let snapshot: StateSnapshot
    public let actions: [ActionRequest]
}

public enum SimulationRunner {
    public static func run(_ scenario: SimulationScenario) throws -> [SimulationStep] {
        var driver = try Driver()
        driver.send(.session(.activeOwner))
        let enrollment = try Enrollment(id: UUID(), vendorID: 0x1050,
                                        acceptedProductIDs: [0x0407], serial: "SIMULATION-ONLY")
        driver.send(.configure(try ProtectionPolicy(revision: 1, enrollment: enrollment), expectedRevision: nil))
        driver.healthy()
        driver.send(.arm(expectedRevision: 1), label: "Request arming; await fresh inventory")
        let device = DeviceObservation(instance: 1, vendorID: 0x1050, productID: 0x0407, serial: "SIMULATION-ONLY")
        driver.send(.inventory(scenario == .startupWithoutKey ? [] : [device], driver.epoch), label: "Fresh inventory")
        switch scenario {
        case .startupWithoutKey:
            driver.send(.removed(instance: 1, epoch: driver.epoch), label: "Absent key cannot trigger")
        case .removal, .reconnect:
            driver.send(.removed(instance: 1, epoch: driver.epoch), label: "Bound instance removed")
            if scenario == .reconnect {
                driver.send(.attached(DeviceObservation(instance: 2, vendorID: 0x1050,
                    productID: 0x0407, serial: "SIMULATION-ONLY"), driver.epoch), label: "Reconnect keeps trigger latched")
            }
        case .staleHealth:
            driver.time += 3_000
            driver.send(.tick, label: "Health expired; mock lock fallback only")
        case .sleepWithoutKey:
            driver.send(.willSleep, label: "Sleep invalidates presence")
            driver.send(.didWake, label: "Wake requests fresh evidence")
            driver.healthy()
            driver.send(.inventory([], driver.epoch), label: "Missing after wake; no removal trigger")
        case .disarmFirst:
            let oldEpoch = driver.epoch
            driver.send(.disarm(expectedArming: oldEpoch.arming), label: "Disarm committed")
            driver.send(.removed(instance: 1, epoch: oldEpoch), label: "Old removal is rejected")
        }
        return driver.steps
    }

    private struct Driver {
        var reducer: ProtectionReducer
        var sequences: [EventSource: UInt64] = [:]
        var time: UInt64 = 100
        var steps: [SimulationStep] = []
        var epoch: ObservationEpoch { reducer.snapshot.epoch }

        init() throws {
            reducer = try ProtectionReducer(bootID: UUID(), capabilities:
                RuntimeCapabilities(profile: .simulation, lock: .mockOnly, shutdown: .mockOnly))
        }

        mutating func healthy() {
            for component in HealthComponent.allCases {
                send(.health(HealthObservation(component, generation: reducer.snapshot.healthGeneration, progress: 1)))
            }
        }

        mutating func send(_ event: ProtectionEvent, label: String? = nil) {
            sequences[event.source, default: 0] += 1
            let result = reducer.process(EventEnvelope(bootID: reducer.bootID, source: event.source,
                sequence: sequences[event.source]!, observedAt: time, event: event), at: time)
            if let label {
                steps.append(SimulationStep(label: label, snapshot: result.snapshot,
                    actions: result.effects.compactMap { if case let .action(request) = $0 { request } else { nil } }))
            }
        }
    }
}
