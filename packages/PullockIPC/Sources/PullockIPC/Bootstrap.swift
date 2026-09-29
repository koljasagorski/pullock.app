import Foundation

public struct BootstrapRequest: Equatable, Codable, Sendable {
    public let version: Int
    public let nonce: UUID
    public init(nonce: UUID = UUID()) { version = WireEnvelope.currentVersion; self.nonce = nonce }
}

public struct BootstrapReply: Equatable, Codable, Sendable {
    public let version: Int
    public let nonce: UUID
    public let connectionID: UUID
    public let bootID: UUID
    public init(nonce: UUID, connectionID: UUID, bootID: UUID) {
        version = WireEnvelope.currentVersion; self.nonce = nonce
        self.connectionID = connectionID; self.bootID = bootID
    }
}

/// Non-sensitive nonce exchange precedes WireSession hello. The server generates
/// a fresh connection ID, so clients cannot reuse a previous validation epoch.
public enum BootstrapCodec {
    public static let maximumBytes = 512
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumBytes else { throw WireError.tooLarge }
        return data
    }

    public static func request(_ data: Data) throws -> BootstrapRequest {
        try fields(data, expected: ["version", "nonce"])
        let value: BootstrapRequest
        do { value = try JSONDecoder().decode(BootstrapRequest.self, from: data) }
        catch { throw WireError.malformed }
        guard value.version == WireEnvelope.currentVersion else { throw WireError.unsupportedVersion }
        return value
    }

    public static func reply(_ data: Data, expectedNonce: UUID) throws -> BootstrapReply {
        try fields(data, expected: ["version", "nonce", "connectionID", "bootID"])
        let value: BootstrapReply
        do { value = try JSONDecoder().decode(BootstrapReply.self, from: data) }
        catch { throw WireError.malformed }
        guard value.version == WireEnvelope.currentVersion else { throw WireError.unsupportedVersion }
        guard value.nonce == expectedNonce else { throw WireError.wrongConnection }
        return value
    }

    private static func fields(_ data: Data, expected: Set<String>) throws {
        guard data.count <= maximumBytes else { throw WireError.tooLarge }
        let object: [String: Any]
        do {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw WireError.malformed
            }
            object = value
        } catch { throw WireError.malformed }
        guard Set(object.keys) == expected else { throw WireError.unknownFields }
    }
}
