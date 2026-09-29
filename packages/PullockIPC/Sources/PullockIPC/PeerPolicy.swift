import Foundation
import Security

public enum PeerPolicyError: String, Error, Sendable {
    case invalidTeam, invalidRequirement, invalidOwner, invalidRole, wrongUser, wrongSession
    case inactiveSession, connectionGone, wrongCallingConnection
}

/// Production-only requirements. There is deliberately no ad-hoc, development
/// certificate, arbitrary identifier or caller-provided requirement escape hatch.
public struct DeveloperIDPeerRequirement: Sendable {
    public let role: ProcessRole
    public let text: String

    public init(teamID: String, role: ProcessRole) throws {
        guard teamID.utf8.count == 10,
              teamID.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else {
            throw PeerPolicyError.invalidTeam
        }
        let identifier: String
        switch role {
        case .app: identifier = "app.pullock"
        case .sessionAgent: identifier = "app.pullock.session-agent"
        case .daemon: identifier = "app.pullock.daemon"
        }
        let requirement = """
        anchor apple generic and identifier "\(identifier)" and \
        certificate leaf[subject.OU] = "\(teamID)" and \
        certificate 1[field.1.2.840.113635.100.6.2.6] exists and \
        certificate leaf[field.1.2.840.113635.100.6.1.13] exists
        """
        // Validate before passing to NSXPCConnection, whose API throws an ObjC
        // exception for malformed requirements. Do not validate by PID lookup.
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess,
              compiled != nil else { throw PeerPolicyError.invalidRequirement }
        self.role = role; self.text = requirement
    }
}

/// This state must be obtained by the trusted host from its current owner/session
/// authority. Values in a wire payload must never construct this policy.
public struct OwnerSessionPolicy: Sendable {
    public let uid: UInt32
    public let auditSession: Int32
    public let active: Bool

    public init(uid: UInt32, auditSession: Int32, active: Bool) throws {
        guard uid != 0, uid != UInt32.max, auditSession > 0 else {
            throw PeerPolicyError.invalidOwner
        }
        self.uid = uid; self.auditSession = auditSession; self.active = active
    }

    public func validate(effectiveUID: UInt32, auditSession: Int32) throws {
        guard active else { throw PeerPolicyError.inactiveSession }
        guard effectiveUID == uid else { throw PeerPolicyError.wrongUser }
        guard auditSession == self.auditSession else { throw PeerPolicyError.wrongSession }
    }
}

/// An inbound connection configured for ONE role-specific listener endpoint.
/// Construct once in shouldAcceptNewConnection, before activation. The caller
/// still supplies the exported object/interface and must activate or invalidate.
/// Preparing this object is not an authenticated handshake.
public final class IncomingPeerGate {
    private weak var connection: NSXPCConnection?
    public let role: ProcessRole

    public init(connection: NSXPCConnection, requirement: DeveloperIDPeerRequirement,
                owner: OwnerSessionPolicy) throws {
        guard requirement.role != .daemon else { throw PeerPolicyError.invalidRole }
        try owner.validate(effectiveUID: connection.effectiveUserIdentifier,
                           auditSession: connection.auditSessionIdentifier)
        connection.setCodeSigningRequirement(requirement.text)
        self.connection = connection; self.role = requirement.role
    }

    /// Call synchronously at the start of every exported method, BEFORE any
    /// actor/queue hop. NSXPC checks the requirement on incoming messages. Recheck
    /// owner/session with current trusted state so an accepted connection cannot
    /// outlive a session switch. The wire hello cannot upgrade the fixed role.
    public func validateCurrentCall(owner: OwnerSessionPolicy) throws {
        guard let connection else { throw PeerPolicyError.connectionGone }
        guard NSXPCConnection.current() === connection else { throw PeerPolicyError.wrongCallingConnection }
        try owner.validate(effectiveUID: connection.effectiveUserIdentifier,
                           auditSession: connection.auditSessionIdentifier)
    }
}

/// A single typed byte container avoids decoding attacker-chosen object graphs.
/// The receiver must enforce WireCodec.maximumBytes BEFORE JSON decoding.
@objc public protocol PullockXPCTransport {
    func exchange(_ packet: NSData, reply: @escaping @Sendable (NSData?) -> Void)
}

public enum PullockXPCInterface {
    public static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: PullockXPCTransport.self)
        let selector = #selector(PullockXPCTransport.exchange(_:reply:))
        let allowed = NSSet(object: NSData.self) as! Set<AnyHashable>
        interface.setClasses(allowed, for: selector, argumentIndex: 0, ofReply: false)
        interface.setClasses(allowed, for: selector, argumentIndex: 0, ofReply: true)
        return interface
    }
}

/// Builds an INACTIVE connection in the privileged system Mach namespace. The
/// caller owns invalidation, deadlines, the harmless initial hello and reply
/// validation. Construction alone neither contacts nor authenticates a daemon.
public enum DaemonClientConnection {
    public static func prepare(teamID: String, clientRole: ProcessRole) throws -> NSXPCConnection {
        let endpoint: String
        switch clientRole {
        case .app: endpoint = "app.pullock.daemon.app"
        case .sessionAgent: endpoint = "app.pullock.daemon.session-agent"
        case .daemon: throw PeerPolicyError.invalidRole
        }
        let requirement = try DeveloperIDPeerRequirement(teamID: teamID, role: .daemon)
        let connection = NSXPCConnection(machServiceName: endpoint, options: .privileged)
        connection.setCodeSigningRequirement(requirement.text)
        connection.remoteObjectInterface = PullockXPCInterface.make()
        return connection
    }
}
