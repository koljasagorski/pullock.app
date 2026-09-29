import Darwin
import Foundation
import PullockCore
import PullockIPC
import Synchronization
import SystemConfiguration

/// The diagnostic host can refresh only its own reducer clock. It cannot
/// configure a key, arm, inject USB events or dispatch an action.
public final class DiagnosticHealth: Sendable {
    public let bootID: UUID
    private struct State { var core: ProtectionReducer; var sequence: UInt64 = 0 }
    private let state: Mutex<State>

    public init() throws {
        let boot = UUID()
        bootID = boot
        state = Mutex(State(core: try ProtectionReducer(bootID: boot)))
    }

    public func snapshot() -> StateSnapshot {
        state.withLock { state in
            let now = MonotonicTime.milliseconds
            // Exhaustion freezes progress; it must never wrap into fresh state.
            guard state.sequence < UInt64.max else { return state.core.snapshot }
            state.sequence += 1
            return state.core.process(EventEnvelope(bootID: bootID, source: .clock,
                sequence: state.sequence, observedAt: now, event: .tick), at: now).snapshot
        }
    }
}

/// Access to non-sensitive development health only. Each call checks the
/// primary console UID and kernel audit-session record, not a wire assertion.
/// This is NOT the persistent owner/active-session authority for live actions.
/// auditon is a public but deprecated API; unsupported kernels deny access.
public enum DiagnosticConsoleAccess {
    public static func owner(effectiveUID: UInt32, auditSession: Int32) throws -> OwnerSessionPolicy {
        guard effectiveUID != 0, effectiveUID != UInt32.max, auditSession > 0 else {
            throw PeerPolicyError.invalidOwner
        }
        var consoleUID: uid_t = UInt32.max
        guard let user = SCDynamicStoreCopyConsoleUser(nil, &consoleUID, nil) as String?,
              user != "loginwindow", consoleUID == effectiveUID else { throw PeerPolicyError.inactiveSession }
        var information = auditinfo_addr_t()
        information.ai_asid = auditSession
        guard auditon(A_GETSINFO_ADDR, &information, Int32(MemoryLayout<auditinfo_addr_t>.size)) == 0,
              information.ai_asid == auditSession, information.ai_auid == effectiveUID else {
            throw PeerPolicyError.wrongSession
        }
        let required = UInt64(AU_SESSION_FLAG_HAS_GRAPHIC_ACCESS.rawValue)
            | UInt64(AU_SESSION_FLAG_HAS_CONSOLE_ACCESS.rawValue)
            | UInt64(AU_SESSION_FLAG_HAS_AUTHENTICATED.rawValue)
        guard information.ai_flags & required == required,
              information.ai_flags & UInt64(AU_SESSION_FLAG_IS_REMOTE.rawValue) == 0 else {
            throw PeerPolicyError.inactiveSession
        }
        return try OwnerSessionPolicy(uid: effectiveUID, auditSession: auditSession, active: true)
    }
}
