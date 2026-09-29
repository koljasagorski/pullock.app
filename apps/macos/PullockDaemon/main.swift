import Foundation
import PullockCore
import PullockIPC

// This executable is never installed or launched as root by the M2 project.
// No real action module, service plist, persistence, or XPC listener is linked.
guard CommandLine.arguments.dropFirst().isEmpty || CommandLine.arguments.dropFirst() == ["--self-check"] else {
    print("Usage: PullockDaemon [--self-check]; development shell only")
    exit(64)
}
do {
    let reducer = try ProtectionReducer(bootID: UUID())
    print("{\"component\":\"daemon\",\"protocolVersion\":\(WireEnvelope.currentVersion),\"status\":\"\(reducer.snapshot.status.rawValue)\",\"listenerStarted\":false,\"realActions\":0}")
} catch {
    print("{\"component\":\"daemon\",\"selfCheck\":\"failed\"}")
    exit(1)
}
