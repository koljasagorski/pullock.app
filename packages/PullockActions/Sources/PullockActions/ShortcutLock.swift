import Carbon
import CoreGraphics
import Foundation

public enum LockShortcutError: String, Error, Sendable {
    case permissionRequired, inactiveSession, unsupportedKeyboardLayout, eventCreationFailed
}

public enum LockSubmission: String, Sendable { case requested }

@MainActor
protocol ShortcutBackend {
    var permitted: Bool { get }
    var activeSession: Bool { get }
    func requestPermission() -> Bool
    func qKeyCode() -> UInt16?
    func postControlCommandQ(keyCode: UInt16) throws
}

/// Requests Apple's documented Control–Command–Q shortcut. Event posting has
/// no lock-success acknowledgement, so this type cannot return "confirmed".
/// Construction/preflight never request permission or post an input event.
@MainActor
public struct ShortcutLock {
    private let backend: any ShortcutBackend
    public init() { backend = QuartzShortcutBackend() }
    init(backend: any ShortcutBackend) { self.backend = backend }

    public var permissionGranted: Bool { backend.permitted }

    public func preflight() throws {
        guard backend.permitted else { throw LockShortcutError.permissionRequired }
        guard backend.activeSession else { throw LockShortcutError.inactiveSession }
        guard backend.qKeyCode() != nil else { throw LockShortcutError.unsupportedKeyboardLayout }
    }

    /// The UI calls this only from the user's explicit permission button.
    @discardableResult public static func requestPermission() -> Bool { CGRequestPostEventAccess() }

    /// Called by the agent only after an explicit, authenticated setup request.
    /// Permission setup never creates or posts a keyboard event.
    @discardableResult public func requestPermissionForActiveSession() throws -> Bool {
        guard backend.activeSession else { throw LockShortcutError.inactiveSession }
        return backend.permitted || backend.requestPermission()
    }

    @discardableResult public func requestLock() throws -> LockSubmission {
        try preflight()
        guard let keyCode = backend.qKeyCode() else { throw LockShortcutError.unsupportedKeyboardLayout }
        try backend.postControlCommandQ(keyCode: keyCode)
        return .requested
    }
}

@MainActor
private struct QuartzShortcutBackend: ShortcutBackend {
    var permitted: Bool { CGPreflightPostEventAccess() }
    func requestPermission() -> Bool { CGRequestPostEventAccess() }

    var activeSession: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let uid = session[kCGSessionUserIDKey as String] as? NSNumber,
              uid.uint32Value == geteuid(),
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true else { return false }
        return true
    }

    func qKeyCode() -> UInt16? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard CFDataGetLength(data) >= MemoryLayout<UCKeyboardLayout>.size,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        // Resolve Q with the Command modifier, including layouts whose Command
        // layer differs from ordinary typing. Never fall back to a guessed key.
        for code: UInt16 in 0..<128 {
            var deadKey: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), UInt32(cmdKey >> 8),
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKey,
                characters.count, &length, &characters)
            if status == noErr, length == 1, characters[0] == 0x71 || characters[0] == 0x51 { return code }
        }
        return nil
    }

    func postControlCommandQ(keyCode: UInt16) throws {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw LockShortcutError.eventCreationFailed
        }
        // Recheck immediately before posting. Build both events first so an
        // allocation failure cannot leave a synthetic key-down without key-up.
        guard permitted else { throw LockShortcutError.permissionRequired }
        guard activeSession else { throw LockShortcutError.inactiveSession }
        down.flags = [.maskCommand, .maskControl]
        up.flags = [.maskCommand, .maskControl]
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
