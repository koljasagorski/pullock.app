import Foundation
import PullockCore
import PullockIPC

// M2 development executable only. No listener, background registration, or lock
// adapter. A future signed M4 target must authenticate both sides before IPC.
guard CommandLine.arguments.dropFirst().isEmpty || CommandLine.arguments.dropFirst() == ["--self-check"] else {
    print("Usage: PullockSessionAgent [--self-check]; development shell only")
    exit(64)
}
let capabilities = RuntimeCapabilities()
print("{\"component\":\"sessionAgent\",\"protocolVersion\":\(WireEnvelope.currentVersion),\"lockQualified\":\(capabilities.permits(capabilities.lock)),\"listenerStarted\":false,\"realActions\":0}")
