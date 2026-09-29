import Foundation
import PullockCore
import PullockIPC
import PullockServices

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--monitor-health"] {
    guard geteuid() != 0 else { exit(78) }
    do {
        let trust = try ServiceTrust.developmentPeer(role: .daemon)
        Task {
            while !Task.isCancelled {
                do {
                    let client = try NativeHealthClient(trust: trust, clientRole: .sessionAgent)
                    do {
                        try await client.connect()
                        while !Task.isCancelled {
                            _ = try await client.health()
                            try await Task.sleep(for: .seconds(1))
                        }
                    } catch { /* No action fallback exists in this diagnostic build. */ }
                    await client.close()
                } catch { /* Retry only the same fixed, authenticated endpoint. */ }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        RunLoop.main.run()
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
