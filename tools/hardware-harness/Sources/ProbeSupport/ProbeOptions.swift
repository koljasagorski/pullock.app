public enum ProbeCommand: Equatable, Sendable {
    case inspect
    case watch(seconds: Int)
    case simulate
    case help
}

public struct ProbeUsageError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

public func parseCommand(_ arguments: [String]) throws -> ProbeCommand {
    switch arguments {
    case [], ["inspect"]: return .inspect
    case ["--help"], ["-h"], ["help"]: return .help
    case ["simulate"]: return .simulate
    case ["watch"]: return .watch(seconds: 30)
    default:
        if arguments.count == 3, arguments[0] == "watch", arguments[1] == "--seconds",
           let seconds = Int(arguments[2]), (1...3600).contains(seconds) {
            return .watch(seconds: seconds)
        }
        throw ProbeUsageError("Use inspect, simulate, or watch --seconds <1...3600>. No real-action options exist.")
    }
}
