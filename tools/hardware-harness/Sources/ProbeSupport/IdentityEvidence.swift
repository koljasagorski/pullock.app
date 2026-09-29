import CoreFoundation
import CryptoKit
import Foundation

/// Observed descriptors are evidence for investigation, never enrollment approval.
public enum SerialEvidence: Equatable, Sendable {
    case missing
    case invalid
    case conflicting
    case presentUnqualified(value: String, sources: [String])

    public static func read(_ properties: [String: Any], keys: [String]) -> Self {
        var observations: [(String, String)] = []
        for key in keys {
            guard let value = properties[key] else { continue }
            guard let string = boundedString(value),
                  !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .invalid
            }
            observations.append((key, string))
        }
        guard let first = observations.first else { return .missing }
        guard observations.allSatisfy({ $0.1 == first.1 }) else { return .conflicting }
        // Preserve case and whitespace: normalization must not collapse distinct keys.
        return .presentUnqualified(value: first.1, sources: observations.map(\.0))
    }

    public var status: String {
        switch self {
        case .missing: "missing"
        case .invalid: "invalid"
        case .conflicting: "conflicting"
        case .presentUnqualified: "present_unqualified"
        }
    }
}

/// Reject booleans, strings, floating-point descriptors and out-of-range values.
public func usbIdentifier(_ value: Any?) -> UInt16? {
    guard let value,
          CFGetTypeID(value as CFTypeRef) == CFNumberGetTypeID(),
          let number = value as? NSNumber else { return nil }
    let cfNumber = unsafeBitCast(number, to: CFNumber.self)
    guard !CFNumberIsFloatType(cfNumber),
          number.int64Value >= 0, number.int64Value <= Int64(UInt16.max) else { return nil }
    return UInt16(number.int64Value)
}

public func boundedString(_ value: Any, limit: Int = 256) -> String? {
    guard CFGetTypeID(value as CFTypeRef) == CFStringGetTypeID(),
          let string = value as? String,
          !string.isEmpty, string.utf8.count <= limit,
          !string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
        return nil
    }
    return string
}

/// Random key exists only in memory; tokens cannot correlate separate runs or
/// be enumerated using the small space of possible numeric serial numbers.
public struct ReportRedactor: Sendable {
    private let key = SymmetricKey(size: .bits256)

    public init() {}

    public func token(domain: String, value: String) -> String {
        let digest = HMAC<SHA256>.authenticationCode(
            for: Data("\(domain)\u{0}\(value)".utf8), using: key
        )
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    public func fields(for evidence: SerialEvidence) -> [String: String] {
        var fields = ["serial_status": evidence.status, "enrollment": "not_qualified"]
        if case let .presentUnqualified(value, sources) = evidence {
            fields["serial_token"] = token(domain: "serial", value: value)
            fields["serial_sources"] = sources.joined(separator: ",")
        }
        return fields
    }
}
