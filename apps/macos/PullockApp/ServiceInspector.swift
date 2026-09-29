import Foundation
import Observation
import PullockCore
import PullockIPC
import PullockServices
import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class ServiceInspector {
    private(set) var daemon = "Not checked"
    private(set) var agent = "Not checked"
    private(set) var connection = "Not connected"
    private(set) var message: String?
    private(set) var snapshot: StateSnapshot?
    private(set) var devices: [WireDevice] = []
    private(set) var selectedInstance: UInt64?
    private(set) var selectionMessage = "Choose a USB connection reported by the background service."
    private(set) var busy = false
    @ObservationIgnored private var client: NativeHealthClient?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var pendingSelection: (payload: WirePayload, instance: UInt64)?
    @ObservationIgnored private let daemonService = SMAppService.daemon(plistName: "app.pullock.daemon.development.plist")
    @ObservationIgnored private let agentService = SMAppService.agent(plistName: "app.pullock.session-agent.development.plist")

    var registrationAvailable: Bool {
        Bundle.main.bundleURL.deletingLastPathComponent().path == "/Applications"
            && (try? ServiceTrust.developmentPeer(role: .daemon)) != nil
    }

    func refresh() {
        daemon = Self.label(daemonService.status)
        agent = Self.label(agentService.status)
    }

    func register() {
        guard registrationAvailable, !busy else { return }
        message = nil
        // Each status remains visible if only one registration succeeds.
        do {
            if daemonService.status == .notRegistered || daemonService.status == .notFound { try daemonService.register() }
            if agentService.status == .notRegistered || agentService.status == .notFound { try agentService.register() }
            message = "Approve the background service in macOS Login Items if requested. Registration alone does not provide protection."
        } catch {
            message = "macOS could not complete registration. A notarized app in Applications and system approval are required."
        }
        refresh()
    }

    func unregister() async {
        guard !busy else { return }
        busy = true
        defer { busy = false; refresh() }
        await disconnect()
        var failed = false
        for service in [agentService, daemonService] where service.status != .notRegistered && service.status != .notFound {
            do { try await service.unregister() } catch { failed = true }
        }
        message = failed ? "macOS could not remove every registration. Check the statuses and retry." : "Diagnostic services unregistered."
    }

    func connect() {
        guard polling == nil else { return }
        message = nil; connection = "Connecting…"
        polling = Task { [weak self] in
            guard let self else { return }
            do {
                let client = try NativeHealthClient(trust: .developmentPeer(role: .daemon), clientRole: .app)
                self.client = client
                try await client.connect()
                while !Task.isCancelled {
                    if let pending = pendingSelection {
                        pendingSelection = nil
                        guard case .snapshot = try await client.request(pending.payload) else { throw HealthClientError.invalidReply }
                        selectedInstance = pending.instance
                        selectionMessage = "Connection selected in the background service. Automatic protection is not active."
                        busy = false
                    }
                    guard case let .devices(inventory, state) = try await client.request(.getDevices) else {
                        throw HealthClientError.invalidReply
                    }
                    devices = inventory; snapshot = state
                    if state.issues.contains(.selectionExpired) {
                        selectedInstance = nil
                        selectionMessage = "Selection expired. Choose a current USB connection again."
                    }
                    connection = "Authenticated device connection"
                    try await Task.sleep(for: .seconds(1))
                }
            } catch {
                snapshot = nil; devices = []; selectedInstance = nil
                connection = "Connection unavailable"
                message = "The service must be registered, approved and signed with the same Apple certificate as this app."
            }
            if let client = self.client { await client.close() }
            self.client = nil; self.polling = nil; self.pendingSelection = nil; self.busy = false
            refresh()
        }
    }

    func disconnect() async {
        polling?.cancel()
        let task = polling
        if let client { await client.close() }
        await task?.value
        polling = nil; client = nil; snapshot = nil; devices = []; selectedInstance = nil
        pendingSelection = nil; busy = false; connection = "Not connected"
    }

    func choose(_ device: WireDevice) {
        guard !busy, polling != nil, let state = snapshot, state.generatedAt <= MonotonicTime.milliseconds,
              MonotonicTime.milliseconds < state.validUntil, devices.contains(device),
              (state.policyRevision ?? 0) < UInt64.max else { return }
        do {
            let connection = try ConnectionIdentity(bootID: state.bootID, watcher: state.epoch.watcher,
                power: state.epoch.power, instance: device.instance)
            let enrollment = try Enrollment(id: UUID(), vendorID: device.vendorID, productID: device.productID, connection: connection)
            let policy = try ProtectionPolicy(revision: (state.policyRevision ?? 0) + 1, enrollment: enrollment)
            pendingSelection = (.configure(policy: policy, expectedRevision: state.policyRevision), device.instance)
            busy = true; selectionMessage = "Confirming this connection with the background service…"
        } catch { selectionMessage = "This connection cannot be selected. Refresh the device list." }
    }

    private static func label(_ value: SMAppService.Status) -> String {
        switch value {
        case .notRegistered: "Not registered"
        case .enabled: "Registered and approved"
        case .requiresApproval: "Awaiting macOS approval"
        case .notFound: "Not found or not registered"
        @unknown default: "Unknown macOS state"
        }
    }
}

struct ServiceInspectorView: View {
    @Environment(ServiceInspector.self) private var inspector
    @State private var confirmRegistration = false

    var body: some View {
        Form {
            Section {
                Text("Diagnostic services").font(.title.bold())
                Text("Test the background connection. These diagnostic services cannot lock or shut down your Mac.")
                    .foregroundStyle(.secondary)
            }
            Section("macOS registration") {
                LabeledContent("System service", value: inspector.daemon)
                LabeledContent("Session agent", value: inspector.agent)
                HStack {
                    Button("Register diagnostic services") { confirmRegistration = true }
                        .disabled(!inspector.registrationAvailable || inspector.busy)
                    Button("Unregister") { Task { await inspector.unregister() } }.disabled(inspector.busy)
                    Button("Refresh") { inspector.refresh() }
                }
                if !inspector.registrationAvailable {
                    Text("Registration requires an Apple-signed app installed in Applications. This local build is not ready for service installation.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button("Open macOS Login Items") { SMAppService.openSystemSettingsLoginItems() }
            }
            Section("Connection") {
                Text(inspector.connection)
                if let snapshot = inspector.snapshot {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        LabeledContent("Protection", value: snapshot.isProtected(at: MonotonicTime.milliseconds) ? "Unexpected — stop diagnostics" : "Unavailable")
                        Text("Daemon state: \(snapshot.displayStatus(at: MonotonicTime.milliseconds).rawValue.uppercased())")
                    }
                }
                HStack {
                    Button("Check connection") { inspector.connect() }
                    Button("Disconnect") { Task { await inspector.disconnect() } }
                }
            }
            if let message = inspector.message { Section { Text(message).foregroundStyle(.secondary) } }
        }
        .formStyle(.grouped)
        .onAppear { inspector.refresh() }
        .confirmationDialog("Register diagnostic background services?", isPresented: $confirmRegistration) {
            Button("Register services") { inspector.register() }
        } message: {
            Text("This registers one system service and one login agent for connection diagnostics. macOS requests approval. They provide no protection and can be removed here with Unregister.")
        }
    }
}
