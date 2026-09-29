import Foundation
import AppKit
import PullockActions
import PullockCore
import PullockIPC
import PullockServices

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--monitor-health"] {
    guard geteuid() != 0 else { exit(78) }
    do {
        let trust = try ServiceTrust.developmentPeer(role: .daemon)
        let adapter = ShortcutLock()
        let executor = LockActionExecutor { _ in
            try adapter.requestLock()
            return .unknown // A submitted shortcut is not confirmed lock success.
        }
        let receiver = NativeLockReceiver(executor: executor)
        let lease = SessionLeaseGuard(executor: executor)
        let permission = SessionPermissionGate()
        let notifications = NSWorkspace.shared.notificationCenter
        let observers = [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification].map { name in
            notifications.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { lease.suspend(); permission.suspend() }
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { MainActor.assumeIsolated { _ = lease.tick() } }
        timer.activate()
        Task {
            while !Task.isCancelled {
                do {
                    let client = try NativeHealthClient(trust: trust, clientRole: .sessionAgent, lockReceiver: receiver)
                    do {
                        try await client.connect()
                        _ = try await client.health()
                        var state = try await client.enableLockDelivery()
                        try lease.observe(state)
                        while !Task.isCancelled {
                            let permissionTicket = permission.ticket
                            let available: Bool
                            do { try adapter.preflight(); available = true } catch { available = false }
                            let response = try await client.request(.sessionReadiness(generation: state.healthGeneration,
                                progress: MonotonicTime.milliseconds, lockAvailable: available))
                            switch response {
                            case let .snapshot(next): state = next
                            case let .agentPermission(id, requestedAt, expiresAt, next):
                                state = next
                                _ = try? permission.handle(id: id, requestedAt: requestedAt, expiresAt: expiresAt, state: next,
                                    ticket: permissionTicket) { _ = try adapter.requestPermissionForActiveSession() }
                                let acknowledgement = try await client.request(.agentPermissionHandled(id: id))
                                guard case let .snapshot(updated) = acknowledgement else { throw HealthClientError.invalidReply }
                                state = updated
                            default: throw HealthClientError.invalidReply
                            }
                            try lease.observe(state)
                            try await Task.sleep(for: .seconds(1))
                        }
                    } catch { permission.suspend() /* Reconnect without replaying setup or actions. */ }
                    await client.close()
                } catch { /* Retry only the same fixed, authenticated endpoint. */ }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        withExtendedLifetime((receiver, lease, timer, observers)) { RunLoop.main.run() }
        exit(0)
    } catch {
        fputs("Pullock diagnostic agent requires an Apple signing certificate.\n", stderr)
        exit(78)
    }
}
guard arguments.isEmpty || arguments == ["--self-check"] else {
    print("Usage: PullockSessionAgent [--self-check | --monitor-health]")
    exit(64)
}
let capabilities = RuntimeCapabilities()
print("{\"component\":\"sessionAgent\",\"protocolVersion\":\(WireEnvelope.currentVersion),\"lockQualified\":\(capabilities.permits(capabilities.lock)),\"listenerStarted\":false,\"realActions\":0}")
