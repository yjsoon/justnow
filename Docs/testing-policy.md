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

## Candidate rules from the OverlayTimelineTests pilot

These came out of the first round and still need independent review before they guide other files.

- **In-app validation boundary.** When the only caller validates an input first, that boundary's test witnesses the callee's defensive guard. Example: `TimelineScrollDirection.navigationDelta` rejects non-finite deltas before `OverlayViewModel.scrollBy`, so the view model's NaN test was removed.
- **Hosted native tests as witnesses.** A hosted AppKit/SwiftUI test that drives the same view-model call and asserts the same state counts as a witness. Example: `NativeSwiftUIValidationTests` refocuses search and checks selection, query, and results, replacing the view-model-only refocus test.
- **Clock-rollback normalisation.** Keep one consumer witness per subsystem that relies on `timelineSpanBounds` normalising reversed spans (overlay search scope), and accept the loss for presentation-only consumers (Home/End, resolver containment).
- **Performance-only contracts.** Prefetch window and key tests were accepted losses because images still load on demand. A deliberate performance design with a unique witness that guards against an easy refactor (cached timeline decoration not re-observed on scrub) was kept.
