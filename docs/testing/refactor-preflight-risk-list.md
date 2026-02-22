# Refactor Preflight Risk List (2026-02-22)

## Protected by tests now

- Virtual display edit-save decision logic:
  - `VirtualDisplayEditSaveAnalyzer` unit tests cover validation, rebuild/apply boundary, and max-pixels rebuild trigger.
- Create flow input validation:
  - `CreateVirtualDisplayInputValidator` unit tests cover preset/custom mode dedup, invalid input rejection, and serial/name initialization.
- Primary display fallback scheduler:
  - `PrimaryDisplayFallbackCoordinator` unit tests cover start/stop idempotency, recovery attempts, and post-recovery stop.
- App rebuild presentation lifecycle:
  - `RebuildPresentationState` and `AppHelper` tests cover concurrent rebuild guard, failure/retry, success badge lifecycle, and dependent stream stop.
- Virtual display persistence fallbacks:
  - `VirtualDisplayPersistenceService` tests cover load/save/reset exception branches and restore failure collection.
- Virtual display topology/offline high-risk paths:
  - Existing topology/offline suites plus new logic coverage protect callback-missing and topology recovery branches.
- Large VirtualDisplay SwiftUI views:
  - Smoke rendering tests exercise key body branches for `VirtualDisplayView`, `EditVirtualDisplayConfigView`, and `CreateVirtualDisplayObjectView`.

## Remaining high-risk areas

- System-level APIs still depend on platform runtime behavior:
  - `CGVirtualDisplay` creation/apply/termination and CoreGraphics callback timing can still regress outside unit simulation.
- UI interaction semantics are still smoke-level:
  - Rendering is covered, but full user-interaction assertions still rely on UI smoke/integration tests.
- Non-virtual-display subsystems were not deeply expanded in this pass:
  - Sharing Web stack and capture pipeline remain mostly at existing depth.

## Gate result summary

- Unit test gate: passed.
- Coverage guard: passed with `target_line_coverage >= 0.40`.
- Local stability: 3 consecutive full `unit_gate` runs passed.
