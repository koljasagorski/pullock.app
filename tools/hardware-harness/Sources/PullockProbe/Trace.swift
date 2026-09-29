import Darwin
import Foundation

struct TraceEvent: Encodable {
    let schemaVersion = 1
    let sequence: Int
    let elapsedNanoseconds: UInt64
    let source: String
    let event: String
    let fields: [String: String]
}

/// Buffer bounded traces so stdout/disk cannot delay a power acknowledgement.
/// All access is confined to the main actor; flush only after observers stop.
@MainActor
final class Trace {
    private let start = mach_continuous_time()
    private var timebase = mach_timebase_info_data_t()
    private var events: [TraceEvent] = []
    private(set) var truncated = false
    private(set) var failed = false

    init() { mach_timebase_info(&timebase) }

    func record(_ source: String, _ event: String, _ fields: [String: String] = [:]) {
        guard events.count < 10_000 else { truncated = true; failed = true; return }
        let ticks = mach_continuous_time() - start
        let nanos = (ticks / UInt64(timebase.denom)) * UInt64(timebase.numer)
            + (ticks % UInt64(timebase.denom)) * UInt64(timebase.numer) / UInt64(timebase.denom)
        events.append(TraceEvent(sequence: events.count + 1, elapsedNanoseconds: nanos,
                                 source: source, event: event, fields: fields))
    }

    func error(_ operation: String, code: Int32? = nil) {
        failed = true
        var fields = ["operation": operation]
        if let code { fields["code"] = String(code) }
        record("probe", "error", fields)
    }

    func flush() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for event in events {
            var data = try encoder.encode(event)
            data.append(0x0A)
            try FileHandle.standardOutput.write(contentsOf: data)
        }
        if truncated {
            try FileHandle.standardOutput.write(contentsOf:
                Data("{\"event\":\"trace_truncated\",\"complete\":false}\n".utf8))
        }
    }
}
