import Darwin
import Foundation
import PullockCore
import PullockIPC
@testable import PullockServices
@testable import PullockDaemonRuntime
import Security
import Testing

/// Real signed anonymous XPC in both directions; only hardware and the final
/// action are injected. This target cannot import a real input-event adapter.
@MainActor
private final class ActionIntegration {
    var devices = [WireDevice(instance: 12, vendorID: 0x1234, productID: 0x4321, name: "Selected"),
                   WireDevice(instance: 99, vendorID: 0x2222, productID: 0x1111, name: "Other")]
    var calls: [ActionID] = []
    var agentListener: NativeHealthListener?
    let handoff = MainActorHandoff()
    lazy var executor: LockActionExecutor = LockActionExecutor { id in self.calls.append(id); return .unknown }
    var delivery: LockDeliveryDriver?
    lazy var host: DaemonCoordinator = try! DaemonCoordinator(capabilities: .init(profile: .live, lock: .qualified),
        readInventory: { [unowned self] in self.devices },
        validateOwner: Self.owner,
        actionSink: { [unowned self] request in
            if let owner = self.host.currentOwner { self.delivery?.submit(request, owner: owner) }
        }, lockRouteAvailable: { [unowned self] owner in self.agentListener?.lockRouteAvailable(for: owner) == true })

    nonisolated static func owner(uid: UInt32, session: Int32) throws -> OwnerSessionPolicy {
        try OwnerSessionPolicy(uid: uid, auditSession: session, active: true)
    }

    func listener(role: ProcessRole, requirement: String) throws -> NativeHealthListener {
        let host = self.host, handoff = self.handoff, cache = host.cache
        return NativeHealthListener(testTrust: try ServiceTrust(requirement: requirement, role: role, development: true),
            boot: host.bootID, owner: Self.owner, snapshot: { cache.load() }, command: { peer, payload, receivedAt in
                let work = { @MainActor @Sendable in
                    try host.command(role: peer.role, uid: peer.owner.uid, session: peer.owner.auditSession,
                        receivedAt: receivedAt, payload: payload)
                }
                if Thread.isMainThread { return try MainActor.assumeIsolated { try work() } }
                return try handoff.perform(work)
            })
    }

    func prepareDelivery() {
        delivery = LockDeliveryDriver(deliver: { [weak self] request, owner in
            guard let listener = self?.agentListener else { throw LockTransportError.unavailable }
            return try await listener.deliverLock(request, owner: owner)
        }, completed: { [weak self] result, owner in self?.host.actionCompleted(result, for: owner) })
    }

    func stop() { delivery?.stop(); host.stop() }
}

private func integrationRequirement() throws -> String {
    var own: SecCode?
    #expect(SecCodeCopySelf([], &own) == errSecSuccess)
    var code: SecStaticCode?
    #expect(SecCodeCopyStaticCode(try #require(own), [], &code) == errSecSuccess)
    var information: CFDictionary?
    #expect(SecCodeCopySigningInformation(try #require(code), SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess)
    let fields = try #require(information as? [String: Any])
    let digest = try #require(fields[kSecCodeInfoUnique as String] as? Data)
    #expect(digest.count == 20)
    return "cdhash H\"\(digest.map { String(format: "%02x", $0) }.joined())\""
}

@Test(.timeLimit(.minutes(1))) @MainActor
func selectedRemovalTraversesAuthenticatedCommandsAndReverseActionExactlyOnce() async throws {
    let fixture = ActionIntegration(), requirement = try integrationRequirement()
    fixture.prepareDelivery()
    let appListener = try fixture.listener(role: .app, requirement: requirement)
    let agentListener = try fixture.listener(role: .sessionAgent, requirement: requirement)
    fixture.agentListener = agentListener
    fixture.host.watcherStarted(); fixture.host.pulse()
    appListener.start(); agentListener.start()
    defer { fixture.stop(); appListener.stop(); agentListener.stop(); fixture.agentListener = nil }
    let trust = try ServiceTrust(requirement: requirement, role: .daemon, development: true)
    let app = try NativeHealthClient(testEndpoint: appListener.endpoint, trust: trust,
        clientRole: .app, expectedUID: geteuid())
    let agent = try NativeHealthClient(testEndpoint: agentListener.endpoint, trust: trust,
        clientRole: .sessionAgent, expectedUID: geteuid(), lockReceiver: NativeLockReceiver(executor: fixture.executor))
    try await app.connect(); try await agent.connect()
    _ = try await agent.enableLockDelivery()
    let inventory = try await app.request(.getDevices)
    guard case let .devices(devices, state) = inventory else { Issue.record("Missing inventory"); return }
    let device = try #require(devices.first { $0.instance == 12 })
    let selection = try ConnectionIdentity(bootID: state.bootID, watcher: state.epoch.watcher,
        power: state.epoch.power, instance: device.instance)
    let policy = try ProtectionPolicy(revision: 1, enrollment: Enrollment(id: UUID(), vendorID: device.vendorID,
        productID: device.productID, connection: selection))
    _ = try await app.request(.configure(policy: policy, expectedRevision: nil))
    fixture.host.pulse()
    _ = try await agent.request(.sessionReadiness(generation: fixture.host.cache.load().healthGeneration,
        progress: 1, lockAvailable: false))
    _ = try await app.request(.requestAgentPermission)
    let setup = try await agent.request(.sessionReadiness(generation: fixture.host.cache.load().healthGeneration,
        progress: 2, lockAvailable: false))
    guard case let .agentPermission(id, requestedAt, expiresAt, setupState) = setup else {
        Issue.record("Missing permission setup over authenticated XPC"); return
    }
    let permission = SessionPermissionGate()
    var permissionCalls = 0
    #expect(permission.handle(id: id, requestedAt: requestedAt, expiresAt: expiresAt,
        state: setupState, ticket: permission.ticket) { permissionCalls += 1 })
    #expect(permissionCalls == 1 && fixture.calls.isEmpty)
    _ = try await agent.request(.agentPermissionHandled(id: id))
    _ = try await agent.request(.sessionReadiness(generation: fixture.host.cache.load().healthGeneration,
        progress: 3, lockAvailable: true))
    _ = try await app.request(.arm(expectedRevision: 1))
    #expect(fixture.host.cache.load().isProtected(at: MonotonicTime.milliseconds))

    fixture.devices.removeAll { $0.instance == 99 }
    fixture.host.removed(99)
    #expect(fixture.calls.isEmpty && fixture.host.cache.load().status == .armed)
    fixture.devices = []
    fixture.host.removed(12); fixture.host.removed(12)
    for _ in 0..<100 where fixture.host.cache.load().lockOutcome != .unknown {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(fixture.calls.count == 1)
    let action = try #require(fixture.calls.first)
    #expect(action.kind == .lock && action.cause == .removal)
    #expect(fixture.host.cache.load().lockOutcome == .unknown)
    let trigger = fixture.host.cache.load().trigger
    #expect(trigger != nil)
    fixture.devices = [WireDevice(instance: 13, vendorID: device.vendorID, productID: device.productID, name: device.name)]
    fixture.host.inventoryChanged()
    #expect(fixture.host.cache.load().trigger == trigger && fixture.calls.count == 1)
    await app.close(); await agent.close()
}
