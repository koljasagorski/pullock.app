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
    private(set) var mayBeArmed = false
    @ObservationIgnored private var client: NativeHealthClient?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var pendingCommand: (payload: WirePayload, instance: UInt64?)?
    @ObservationIgnored private let daemonService = SMAppService.daemon(plistName: "app.pullock.daemon.development.plist")
    @ObservationIgnored private let agentService = SMAppService.agent(plistName: "app.pullock.session-agent.development.plist")

    var registrationAvailable: Bool {
        Bundle.main.bundleURL.deletingLastPathComponent().path == "/Applications"
            && (try? ServiceTrust.developmentPeer(role: .daemon)) != nil
    }

    var freshSnapshot: StateSnapshot? {
        guard let snapshot, snapshot.generatedAt <= MonotonicTime.milliseconds,
              MonotonicTime.milliseconds < snapshot.validUntil else { return nil }
        return snapshot
    }
    var canChoose: Bool { !busy && freshSnapshot?.armIntent == false && freshSnapshot?.trigger == nil }
    var canArm: Bool {
        guard !busy, selectedInstance != nil, let state = freshSnapshot else { return false }
        return !state.armIntent && state.trigger == nil && state.matchingDeviceCount == 1 && state.issues.isEmpty
    }
    var lockRouteReady: Bool {
        guard let state = freshSnapshot else { return false }
        return !state.issues.contains { issue in
            switch issue {
            case .missingHealth(.agent), .staleHealth(.agent), .unhealthy(.agent),
                 .missingHealth(.lockPath), .staleHealth(.lockPath), .unhealthy(.lockPath), .lockUnqualified: true
            default: false
            }
        }
    }

    var protectionLabel: String {
        guard let state = freshSnapshot else { return mayBeArmed ? "Connection lost · lock request may follow" : "Not connected" }
        if state.trigger != nil {
            switch state.lockOutcome {
            case .unknown: return "Lock outcome unknown · verify the lock screen"
            case .failed: return "Lock request failed"
            default: return "Device disconnected · requesting lock"
            }
        }
        if state.isProtected(at: MonotonicTime.milliseconds) { return "Armed · lock requests enabled" }
        if state.armIntent { return "Not armed · recovery required" }
        return "Disarmed"
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
        guard !busy, !mayBeArmed else { message = "Disarm Pullock before removing its services."; return }
        busy = true
        defer { busy = false; refresh() }
        await disconnect()
        var failed = false
        for service in [agentService, daemonService] where service.status != .notRegistered && service.status != .notFound {
            do { try await service.unregister() } catch { failed = true }
        }
        message = failed ? "macOS could not remove every registration. Check the statuses and retry." : "Background services unregistered."
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
                    if let pending = pendingCommand {
                        pendingCommand = nil
                        guard case let .snapshot(state) = try await client.request(pending.payload) else { throw HealthClientError.invalidReply }
                        snapshot = state; mayBeArmed = state.armIntent
                        if let instance = pending.instance {
                            selectedInstance = instance
                            selectionMessage = "Device selected. Arm Pullock when you are ready."
                        }
                        busy = false
                    }
                    guard case let .devices(inventory, state) = try await client.request(.getDevices) else {
                        throw HealthClientError.invalidReply
                    }
                    devices = inventory; snapshot = state; mayBeArmed = state.armIntent
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
                message = "The background connection was lost or a command was rejected. Reconnect to check the authoritative state. Services must be approved and signed with the same Apple certificate."
            }
            if let client = self.client { await client.close() }
            self.client = nil; self.polling = nil; self.pendingCommand = nil; self.busy = false
            refresh()
        }
    }

    func disconnect() async {
        guard !mayBeArmed else { message = "Disarm Pullock before disconnecting."; return }
        polling?.cancel()
        let task = polling
        if let client { await client.close() }
        await task?.value
        polling = nil; client = nil; snapshot = nil; devices = []; selectedInstance = nil
        pendingCommand = nil; busy = false; connection = "Not connected"
    }

    func choose(_ device: WireDevice) {
        guard canChoose, polling != nil, let state = snapshot, state.generatedAt <= MonotonicTime.milliseconds,
              MonotonicTime.milliseconds < state.validUntil, devices.contains(device),
              (state.policyRevision ?? 0) < UInt64.max else { return }
        do {
            let connection = try ConnectionIdentity(bootID: state.bootID, watcher: state.epoch.watcher,
                power: state.epoch.power, instance: device.instance)
            let enrollment = try Enrollment(id: UUID(), vendorID: device.vendorID, productID: device.productID, connection: connection)
            let policy = try ProtectionPolicy(revision: (state.policyRevision ?? 0) + 1, enrollment: enrollment)
            pendingCommand = (.configure(policy: policy, expectedRevision: state.policyRevision), device.instance)
            busy = true; selectionMessage = "Confirming this connection with the background service…"
        } catch { selectionMessage = "This connection cannot be selected. Refresh the device list." }
    }

    func arm() {
        guard canArm, let revision = freshSnapshot?.policyRevision else { return }
        pendingCommand = (.arm(expectedRevision: revision), nil)
        busy = true; mayBeArmed = true
    }

    func disarm() {
        guard !busy, let state = freshSnapshot, state.trigger == nil else { return }
        pendingCommand = (.disarm(expectedArming: state.epoch.arming), nil)
        busy = true
    }

    func resetTrigger() {
        guard !busy, let state = freshSnapshot, let id = state.trigger,
              state.lockOutcome?.isTerminal == true else { return }
        pendingCommand = (.resetTrigger(id: id), nil)
        busy = true
    }

    func disarmBeforeQuit() async -> Bool {
        guard mayBeArmed else { return true }
        for _ in 0..<30 where busy { try? await Task.sleep(for: .milliseconds(100)) }
        guard !busy else { return false }
        guard freshSnapshot != nil else { message = "Reconnect and disarm before quitting."; return false }
        if freshSnapshot?.trigger != nil { resetTrigger() } else { disarm() }
        for _ in 0..<60 {
            if !busy, freshSnapshot?.armIntent == false { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        message = "Disarming could not be confirmed. Keep Pullock open and check the connection."
        return false
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
                Text("Background services").font(.title.bold())
                Text("The system service watches your selected USB connection. The session agent requests the screen lock after you arm Pullock.")
                    .foregroundStyle(.secondary)
            }
            Section("macOS registration") {
                LabeledContent("System service", value: inspector.daemon)
                LabeledContent("Session agent", value: inspector.agent)
                HStack {
                    Button("Register services") { confirmRegistration = true }
                        .disabled(!inspector.registrationAvailable || inspector.busy)
                    Button("Unregister") { Task { await inspector.unregister() } }.disabled(inspector.busy || inspector.mayBeArmed)
                    Button("Refresh") { inspector.refresh() }
                }
                if !inspector.registrationAvailable {
                    Text("Registration requires an Apple-signed app installed in Applications. This local build is not ready for service installation.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button("Open macOS Login Items") { SMAppService.openSystemSettingsLoginItems() }
            }
            Section("Screen lock permission") {
                LabeledContent("Session agent", value: inspector.lockRouteReady ? "Ready for lock requests" : "Permission, session or keyboard layout needs checking")
                Text("Allow Pullock Development in macOS Accessibility. If the agent is still unavailable, use the + button there to add the bundled PullockSessionAgent shown by the button below. Pullock checks permission without showing a prompt at login.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Open Accessibility settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Show session agent in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/PullockSessionAgent")])
                    }
                }
            }
            Section("Connection") {
                Text(inspector.connection)
                if let snapshot = inspector.snapshot {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        LabeledContent("Protection", value: inspector.protectionLabel)
                        Text("Daemon state: \(snapshot.displayStatus(at: MonotonicTime.milliseconds).rawValue.uppercased())")
                    }
                }
                HStack {
                    Button("Check connection") { inspector.connect() }
                    Button("Disconnect") { Task { await inspector.disconnect() } }.disabled(inspector.mayBeArmed)
                }
            }
            if let message = inspector.message { Section { Text(message).foregroundStyle(.secondary) } }
        }
        .formStyle(.grouped)
        .onAppear { inspector.refresh() }
        .confirmationDialog("Register Pullock background services?", isPresented: $confirmRegistration) {
            Button("Register services") { inspector.register() }
        } message: {
            Text("This registers one system service and one login agent. Approve them in macOS, choose a USB device, then explicitly arm Pullock to enable lock requests. Disarm before removing services.")
        }
    }
}
