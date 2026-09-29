# PullockUSB

Shared, passive USB observation for the development app and hardware harness. It reads selected IORegistry properties of physical Yubico `IOUSBHostDevice` services. It never opens authentication interfaces or sends device commands.

`USBWatcher` owns attach/termination iterators and a main-queue notification port. Both initial iterators are drained before a one-time inventory reconciliation and readiness event. A null successful snapshot iterator means an empty inventory. Cached descriptors accompany removal events; descriptor reads after termination are unnecessary. Stop and deinitialization release the native resources. Restart creates a new watcher UUID. Failures revoke readiness and require restart; reconciliation does not silently recover health. Inventory is limited to 128 entries.

No periodic USB enumeration is performed. Call `reconcile()` explicitly after a supported observation boundary. Power/session authority belongs to the host, not this library. The hardware harness registers its IOKit power observer first. The development window uses NSWorkspace only to suspend its diagnostic view; it is not the daemon's protection implementation.

`USBDescriptorParser` checks integer types and bounds, selects only the documented property names, preserves exact strings and rejects malformed/conflicting identity evidence. `ReportRedactor` creates per-run keyed HMAC tokens. Raw serials and registry IDs must not enter exported diagnostics or UI snapshots.

`EnrollmentReview` requires disarmed operation, a unique exact serial, a trusted qualified hardware profile, termination of the original instance and a matching new instance in the same watcher epoch. It rechecks current inventory at finalization. Reconnected-device removal and watcher changes invalidate the proof. The authoritative host must also call `invalidate()` on sleep, session, arming or health boundaries. The `disarmed` argument must come from the trusted state owner, never an unvalidated client payload.

There are **no qualified real hardware profiles** in this repository. Test profiles are synthetic fixtures only. The returned `Enrollment` is an in-memory candidate, not a persisted policy or authorization to arm. Persistent storage and daemon integration remain M4 work.

Tests cover missing/conflicting serials, invalid descriptors, unique current inventory, qualified fixture PID variants, duplicate identities, different devices, same-instance false reconnects and epoch invalidation. Real USB removal, power ordering and coexistence still require physical tests; a passing unit suite does not qualify hardware.
