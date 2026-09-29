import Foundation
import PullockCore
import PullockIPC
import PullockServices

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--serve-health"] {
    do {
        guard geteuid() == 0 else { throw PeerPolicyError.invalidOwner }
        let runtime = try DiagnosticHealth()
        let app = try NativeHealthListener(trust: .developmentPeer(role: .app), boot: runtime.bootID,
            owner: DiagnosticConsoleAccess.owner, snapshot: runtime.snapshot)
        let agent = try NativeHealthListener(trust: .developmentPeer(role: .sessionAgent), boot: runtime.bootID,
            owner: DiagnosticConsoleAccess.owner, snapshot: runtime.snapshot)
        app.start(); agent.start()
        withExtendedLifetime((runtime, app, agent)) { RunLoop.main.run() }
        app.stop(); agent.stop()
        exit(0)
    } catch {
        fputs("Pullock diagnostic service could not start.\n", stderr)
        exit(78)
    }
}
guard arguments.isEmpty || arguments == ["--self-check"] else {
    print("Usage: PullockDaemon [--self-check | --serve-health]")
    exit(64)
}
do {
    let reducer = try ProtectionReducer(bootID: UUID())
    print("{\"component\":\"daemon\",\"protocolVersion\":\(WireEnvelope.currentVersion),\"status\":\"\(reducer.snapshot.status.rawValue)\",\"listenerStarted\":false,\"realActions\":0}")
} catch {
    print("{\"component\":\"daemon\",\"selfCheck\":\"failed\"}")
    exit(1)
}
