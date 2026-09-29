@testable import PullockActions
import Testing

@MainActor private final class Backend: ShortcutBackend {
    var permitted = true
    var activeSession = true
    var key: UInt16? = 12
    var posted: [UInt16] = []
    var failure = false
    func qKeyCode() -> UInt16? { key }
    func postControlCommandQ(keyCode: UInt16) throws {
        if failure { throw LockShortcutError.eventCreationFailed }
        posted.append(keyCode)
    }
}

@MainActor @Test func preflightNeverPostsInput() throws {
    let backend = Backend(), adapter = ShortcutLock(backend: Backend())
    try adapter.preflight()
    try ShortcutLock(backend: backend).preflight()
    #expect(backend.posted.isEmpty)
}

@MainActor @Test func missingPermissionInactiveSessionAndUnknownLayoutPreventInput() throws {
    let backend = Backend(), adapter = ShortcutLock(backend: backend)
    backend.permitted = false
    #expect(throws: LockShortcutError.permissionRequired) { try adapter.requestLock() }
    backend.permitted = true; backend.activeSession = false
    #expect(throws: LockShortcutError.inactiveSession) { try adapter.requestLock() }
    backend.activeSession = true; backend.key = nil
    #expect(throws: LockShortcutError.unsupportedKeyboardLayout) { try adapter.requestLock() }
    #expect(backend.posted.isEmpty)
}

@MainActor @Test func submissionUsesResolvedKeyAndNeverClaimsConfirmedLock() throws {
    let backend = Backend(), adapter = ShortcutLock(backend: backend)
    backend.key = 42
    #expect(try adapter.requestLock() == .requested)
    #expect(backend.posted == [42])
}

@MainActor @Test func failedEventCreationDoesNotClaimSubmission() {
    let backend = Backend(), adapter = ShortcutLock(backend: backend)
    backend.failure = true
    #expect(throws: LockShortcutError.eventCreationFailed) { try adapter.requestLock() }
    #expect(backend.posted.isEmpty)
}
