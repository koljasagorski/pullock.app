import Foundation
import PullockCore
import PullockDaemonRuntime
import PullockIPC
import PullockServices

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--inspect-runtime"] {
    do {
        let runtime = try NativeDaemonRuntime()
        defer { runtime.stop() }
        try runtime.start()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let state = runtime.snapshot()
        let progressed = !state.issues.contains(.missingHealth(.daemon)) && !state.issues.contains(.missingHealth(.watcher))
        let count = runtime.observedDeviceCount
        runtime.stop()
        guard progressed, !state.isProtected(at: MonotonicTime.milliseconds) else { exit(1) }
        print("{\"component\":\"daemon\",\"runtimeObservation\":true,\"deviceCount\":\(count),\"listenerStarted\":false,\"realActions\":0}")
        exit(0)
    } catch {
        fputs("Pullock runtime observation could not start.\n", stderr)
        exit(78)
    }
}
if arguments == ["--serve-health"] {
    do {
        guard geteuid() == 0 else { throw PeerPolicyError.invalidOwner }
        let runtime = try NativeDaemonRuntime()
        let app = try NativeHealthListener(trust: .developmentPeer(role: .app), boot: runtime.bootID,
            owner: DiagnosticConsoleAccess.owner, snapshot: runtime.snapshot, command: runtime.commandHandler)
        let agent = try NativeHealthListener(trust: .developmentPeer(role: .sessionAgent), boot: runtime.bootID,
            owner: DiagnosticConsoleAccess.owner, snapshot: runtime.snapshot, command: runtime.commandHandler)
        try runtime.start()
        app.start(); agent.start()
        withExtendedLifetime((runtime, app, agent)) { RunLoop.main.run() }
        app.stop(); agent.stop(); runtime.stop()
        exit(0)
    } catch {
        fputs("Pullock diagnostic service could not start.\n", stderr)
        exit(78)
    }
}
guard arguments.isEmpty || arguments == ["--self-check"] else {
    print("Usage: PullockDaemon [--self-check | --serve-health | --inspect-runtime]")
    exit(64)
}
do {
    let reducer = try ProtectionReducer(bootID: UUID())
    print("{\"component\":\"daemon\",\"protocolVersion\":\(WireEnvelope.currentVersion),\"status\":\"\(reducer.snapshot.status.rawValue)\",\"listenerStarted\":false,\"realActions\":0}")
} catch {
    print("{\"component\":\"daemon\",\"selfCheck\":\"failed\"}")
    exit(1)
}
