# Entwurf für Apple DTS / Feedback — nicht versendet

Subject: Supported local macOS session lock request and confirmation API

We are investigating a directly distributed native macOS application on Apple Silicon, targeting macOS 27.x. A user explicitly arms monitoring of one USB security key. Losing the bound physical USB service should immediately lock that user's interactive session and require normal macOS authentication before access resumes.

A per-user Aqua-session agent would perform the lock, while a small system daemon observes USB presence. We do not require automatic unlocking, credential access, modifications to authorization rules, a screen-covering window, or device management enrollment.

1. Is there a supported public API for the user-session agent to request the same authenticated lock as the system Lock Screen action?
2. Is there a supported public confirmation that this specific session now requires authentication, distinct from submitting a request, display sleep, session deactivation, or starting a screensaver?
3. If posting the documented Control-Command-Q shortcut via public event APIs is the only consumer-app option, what guarantees and limitations apply to keyboard layouts, Secure Input, modal/fullscreen applications, Fast User Switching, and permission revocation? Is using this path for a security claim supported?
4. Do any supported session APIs distinguish an acknowledged request from a completed lock without private notifications or undocumented CGSession dictionary keys?
5. Is there a supported session teardown signal suitable for the user agent to report to its authenticated daemon, covering logout and shutdown without inferring these events from USB termination?

We have reviewed the current public CoreGraphics CGSession/CGEvent headers, AppKit session notifications, Security and ServiceManagement APIs, and the MDM DeviceLock command. We have not identified a documented direct local lock request/confirmation pair. The current investigation uses only passive device observation, non-prompting permission preflight, and mock actions; no real lock implementation is shipped.

No private APIs or changes to system authentication configuration are acceptable for our intended architecture. Guidance on a supported solution, or confirmation that this use case requires a more restricted product scope, would be appreciated.
