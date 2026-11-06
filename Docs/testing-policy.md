# Test Retention Policy

JustNow prunes its XCTest suite with the [minimal-risk-tests](https://github.com/gauravmm/g9k-skills/blob/master/skills/minimal-risk-tests/SKILL.md) method. This note holds the project-specific facts that method asks for. The payoff is maintenance cost: the full suite already runs in about 2.5 minutes in CI.

## Protected failure classes

Do not remove the only detection of these without listing the loss for the maintainer's approval:

- **Privacy:** owner-only storage permissions, backup exclusion, and no-content diagnostics (no query text, OCR text, frame IDs, or paths in logs).
- **Stored history:** loss or corruption of durable frames, metadata, or OCR data, including retention or pruning running while the overlay holds a snapshot.
- **Capture liveness and permission recovery:** capture must resume after the overlay, memory-pressure handling, and transient failures; recovery must not mistake every failure for revoked permission.
- **First-launch permission behavior:** the native TCC prompt resolves before app guidance appears.

Other classes, such as overlay presentation, navigation feel, copy, and prefetch performance, may be accepted as risks when the lost detection is named.

## Local rules

- Tests are app-hosted (`AppDelegate` skips normal startup under XCTest). They use synthetic images, injected temporary directories for `FrameStore`, `TextCache`, and `FrameBuffer`, and isolated or restored preferences. Never point a test at the live Application Support store.
- Pruning stays paused, and the overlay's payload lease stays held, while the overlay is open (see `JustNow/AGENTS.md`). Overlay lifecycle tests around the lease, pruning pause, and capture resume are protected under stored history and capture liveness.
- Validate on a Mac with Xcode: the affected test class with `-only-testing`, then the full suite, using the commands in [local development](local-development.md).

## Cross-file witnesses

Removed tests rely on these retained tests in other files. Do not prune or weaken them without rechecking the original removal.

| Witness | Covers removed test | Contract |
|---|---|---|
| `NativeSwiftUIValidationTests.testSearchCaretScrubRefocusAndSubmitWithoutActivatingWindow` | `OverlayTimelineTests.testRefocusingSearchPreservesItsFilterAndSelectedResult` | `focusSearch()` while searching re-requests focus and keeps the selection, query, scope and results. |
| `TimelineScrollDirectionTests.testNonFiniteDirectionInputIsRejected` | `OverlayTimelineTests.testScrollIgnoresNonFiniteDelta` | Non-finite scroll deltas never reach `OverlayViewModel.scrollBy`. |

## Candidate rules

These came out of the OverlayTimelineTests pilot and were revised after its independent review. They are still candidates.

1. **In-app validation boundary.** A validation boundary's test can witness a callee's defensive guard only when a search confirms that the caller is the callee's sole caller, the input is produced in-process, and the guard protects no protected class. Guards on data read from disk, SQLite, ScreenCaptureKit, restored state or a legacy manifest keep their own witness. Example: the scroll monitor passes deltas through `TimelineScrollDirection.navigationDelta` and `TimelineScrollAccumulator.navigationStep` before `OverlayViewModel.scrollBy`, so the view model's NaN test was removed.
2. **Hosted native tests as witnesses.** A hosted AppKit/SwiftUI test counts as a witness when it cannot be skipped and asserts the same state after the same view-model call. Any assertion of the removed test that the witness does not cover is listed as an accepted loss, or added to the witness. Do not use this rule to claim durability or crash safety unless the witness reopens the store; in-process calls do not prove either.
3. **Clock-rollback normalisation.** For presentation, keep one consumer witness per subsystem that relies on `timelineSpanBounds` normalising reversed spans, and accept losses in the other presentation consumers (Home/End, resolver containment). In storage (`FrameBuffer`, `FrameDatabase`, `HybridFrameRepository`, `CompressedFrameRing`), every point where normalised bounds decide retention, pruning, recovery or eviction keeps its own witness.
4. **Performance-only contracts.** Only latency optimisations with a bounded fallback qualify as performance-only accepted losses. Example: image prefetch into the cost-limited full-image cache, where images still load on demand. This rule excludes memory bounds (cache costs, ring capacity, pressure trimming), disk growth and compaction, capture cadence and throttling, and anything that fails as unbounded growth or a stall. Keep a deliberate performance design that has a unique witness against an easy refactor, such as cached timeline decoration not being re-observed while scrubbing.
5. **Mutation evidence for redundancy.** From round 2 on, every redundancy claim needs a mutation that the named witness kills, run against the full suite so cross-file witnesses show up.
