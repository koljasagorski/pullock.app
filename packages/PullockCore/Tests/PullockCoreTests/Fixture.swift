import Foundation
import PullockCore

struct Fixture {
    static let boot = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let serial = "FIXTURE-PRIVATE-SERIAL"
    static let key = DeviceObservation(instance: 10, vendorID: 0x1050, productID: 0x0407, serial: serial)
    var reducer: ProtectionReducer
    var time: UInt64 = 100
    var sequences: [EventSource: UInt64] = [:]
    var progress: [HealthComponent: UInt64] = [:]
    var epoch: ObservationEpoch { reducer.snapshot.epoch }
    var snapshot: StateSnapshot { reducer.snapshot }

    init(mode: ActionMode = .lock, profile: ExecutionProfile = .simulation,
         lock: ActionQualification = .mockOnly, shutdown: ActionQualification = .mockOnly,
         acknowledgeShutdown: Bool = true) throws {
        reducer = try ProtectionReducer(bootID: Self.boot,
            capabilities: RuntimeCapabilities(profile: profile, lock: lock, shutdown: shutdown))
        send(.session(.activeOwner))
        let enrollment = try Enrollment(id: Self.boot, vendorID: 0x1050,
            acceptedProductIDs: [0x0407, 0x0403], serial: Self.serial)
        send(.configure(try ProtectionPolicy(revision: 1, enrollment: enrollment, mode: mode,
            shutdownAcknowledged: acknowledgeShutdown), expectedRevision: nil))
        healthy()
    }

    @discardableResult
    mutating func send(_ event: ProtectionEvent) -> Transition {
        sequences[event.source, default: 0] += 1
        return reducer.process(EventEnvelope(bootID: Self.boot, source: event.source,
            sequence: sequences[event.source]!, observedAt: time, event: event), at: time)
    }

    mutating func healthy() {
        for component in HealthComponent.allCases {
            progress[component, default: 0] += 1
            send(.health(HealthObservation(component, generation: snapshot.healthGeneration,
                progress: progress[component]!)))
        }
    }

    @discardableResult
    mutating func arm(_ devices: [DeviceObservation] = [Self.key]) -> Transition {
        send(.arm(expectedRevision: 1))
        return send(.inventory(devices, epoch))
    }
}

extension Transition {
    var actions: [ActionRequest] {
        effects.compactMap { if case let .action(request) = $0 { request } else { nil } }
    }
}
