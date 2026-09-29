import CoreGraphics
import Darwin
import Foundation
import ProbeSupport

@main
@MainActor
struct PullockProbe {
    static func main() {
        let command: ProbeCommand
        do { command = try parseCommand(Array(CommandLine.arguments.dropFirst())) }
        catch {
            fputs("Invalid arguments. Use pullock-probe --help. No real-action options exist.\n", stderr)
            exit(64)
        }
        if command == .help {
            print("""
            Pullock M1 hardware probe — observation and mock actions only. NO PROTECTION.

              pullock-probe inspect                 One passive snapshot (default)
              pullock-probe watch [--seconds 1...3600] Observe for 30 seconds by default
              pullock-probe simulate                Synthetic detection example, no hardware

            Watch buffers JSON Lines until the duration ends or Ctrl-C; limit: 10,000 events.
            Only Yubico USB device services are observed. Serial/instance tokens are per run.
            No enrollment, permission prompts, service installation, locking or shutdown.
            Exit: 0 complete probe, 1 probe/output error, 64 invalid arguments.
            A successful probe does not mean compatible hardware or a working lock path.
            """)
            return
        }
        signal(SIGPIPE, SIG_IGN)
        let trace = Trace()
        trace.record("probe", "started", ["mode": String(describing: command),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "actions": "mock_only", "clock": "mach_continuous_time", "protection": "unavailable"])
        if command == .simulate {
            var mock = MockRemovalProbe()
            trace.record("fixture", "startup_absent", ["would_request_lock": String(mock.removed(1))])
            mock.observed(1)
            trace.record("fixture", "attached")
            trace.record("fixture", "removed", ["would_request_lock": String(mock.removed(1)), "executed": "false"])
            trace.record("fixture", "duplicate_removal", ["would_request_lock": String(mock.removed(1))])
            trace.record("fixture", "complete", ["simulated_locks": String(mock.simulatedLocks), "real_actions": "0"])
        } else {
            trace.record("lock", "preflight", ["event_posting_allowed": String(CGPreflightPostEventAccess()),
                "qualified_lock_adapter": "false", "confirmation_available": "false", "permission_requested": "false"])
            let probe = NativeProbe(trace: trace)
            do {
                try probe.start()
                if case let .watch(seconds) = command {
                    wait(seconds: seconds, trace: trace)
                }
            } catch { probe.report(error) }
            probe.stop()
        }
        do { try trace.flush() }
        catch { fputs("Could not write probe output.\n", stderr); exit(1) }
        if trace.failed { exit(1) }
    }

    private static func wait(seconds: Int, trace: Trace) {
        fputs("Observing safely; JSON Lines appear after stop. Ctrl-C ends the probe.\n", stderr)
        let completion = Completion()
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sources = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    trace.record("probe", "interrupted", ["signal": String(number)])
                    completion.finished = true
                }
            }
            source.resume()
            return source
        }
        let timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: false) { _ in
            MainActor.assumeIsolated { completion.finished = true }
        }
        while !completion.finished { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1)) }
        timer.invalidate()
        for source in sources { source.cancel() }
    }
}

@MainActor
private final class Completion {
    var finished = false
}
