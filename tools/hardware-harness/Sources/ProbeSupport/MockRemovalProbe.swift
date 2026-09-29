/// A deliberately small detection experiment, NOT the M2 protection reducer.
/// It records one simulated lock per observed instance, never ARMED/protected.
public struct MockRemovalProbe: Sendable {
    private var instances: Set<UInt64> = []
    private var acceptingPresence = true
    public private(set) var powerEpoch = 0
    public private(set) var simulatedLocks = 0

    public init() {}

    public mutating func observed(_ instance: UInt64) {
        if acceptingPresence { instances.insert(instance) }
    }

    @discardableResult
    public mutating func removed(_ instance: UInt64) -> Bool {
        guard instances.remove(instance) != nil, acceptingPresence else { return false }
        simulatedLocks += 1
        return true
    }

    public mutating func invalidatePresence() {
        powerEpoch += 1
        acceptingPresence = false
        instances.removeAll()
    }

    public mutating func beginFreshObservation() {
        instances.removeAll()
        acceptingPresence = true
    }
}
