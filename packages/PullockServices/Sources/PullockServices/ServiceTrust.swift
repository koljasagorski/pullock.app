import CryptoKit
import Foundation
import PullockIPC
import Security

public enum ServiceTrustError: String, Error, Sendable { case unsigned, missingCertificate, invalidRequirement }

public struct ServiceTrust: Sendable {
    public let requirement: String
    public let role: ProcessRole
    public let development: Bool

    public static func production(teamID: String, role: ProcessRole) throws -> Self {
        let peer = try DeveloperIDPeerRequirement(teamID: teamID, role: role)
        return try Self(requirement: peer.text, role: role, development: false)
    }

    /// Development endpoints pin the current executable's actual signing
    /// certificate and exact peer identifier. No client can supply the pin.
    /// Ad-hoc executables have no certificate and cannot use this path.
    public static func developmentPeer(role: ProcessRole) throws -> Self {
        var own: SecCode?
        guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
              SecCodeCheckValidity(own, [], nil) == errSecSuccess else { throw ServiceTrustError.unsigned }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(own, [], &staticCode) == errSecSuccess, let staticCode else {
            throw ServiceTrustError.unsigned
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let fields = information as? [String: Any],
              let certificates = fields[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let certificate = certificates.first else { throw ServiceTrustError.missingCertificate }
        let certificateData = SecCertificateCopyData(certificate) as Data
        let fingerprint = Insecure.SHA1.hash(data: certificateData).map { String(format: "%02x", $0) }.joined()
        let identifier: String
        switch role {
        case .app: identifier = "app.pullock.development"
        case .sessionAgent: identifier = "app.pullock.session-agent.development"
        case .daemon: identifier = "app.pullock.daemon.development"
        }
        return try Self(requirement: "anchor apple generic and identifier \"\(identifier)\" and certificate leaf = H\"\(fingerprint)\"",
                        role: role, development: true)
    }

    // Internal fixture initializer allows exact test-host requirements for native
    // anonymous XPC tests. There is no runtime/environment bypass in the app.
    init(requirement: String, role: ProcessRole, development: Bool) throws {
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess,
              compiled != nil else { throw ServiceTrustError.invalidRequirement }
        self.requirement = requirement; self.role = role; self.development = development
    }
}
