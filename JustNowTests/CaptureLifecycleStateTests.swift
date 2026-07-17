import XCTest
@testable import JustNow

final class CaptureLifecycleStateTests: XCTestCase {
    func testBlockedStatusPrefersUserPauseOverOverlayAndSession() {
        var state = CaptureLifecycleState()

        XCTAssertTrue(state.toggleUserPause())
        XCTAssertFalse(state.pauseForOverlay(captureWasActive: false, shouldResumeCapture: true))
        XCTAssertFalse(state.pauseForSession(captureWasActive: false, shouldResumeCapture: true))

        XCTAssertEqual(
            state.blockedStatus(isOverlayVisible: true),
            "Paused (User)"
        )
    }

    func testPauseAndResumeForSessionPreservesResumeIntent() {
        var state = CaptureLifecycleState()

        XCTAssertTrue(
            state.pauseForSession(captureWasActive: true, shouldResumeCapture: true)
        )
        XCTAssertTrue(state.isPausedForSession)
        XCTAssertTrue(state.wasCapturingBeforeSession)

        XCTAssertTrue(state.resumeAfterSession())
        XCTAssertFalse(state.isPausedForSession)
        XCTAssertFalse(state.wasCapturingBeforeSession)
    }

    func testPauseAndResumeForOverlayClearsResumeIntentWhenNothingWasRunning() {
        var state = CaptureLifecycleState()

        XCTAssertFalse(
            state.pauseForOverlay(captureWasActive: false, shouldResumeCapture: false)
        )
        XCTAssertTrue(state.isPausedForOverlay)
        XCTAssertFalse(state.wasCapturingBeforeOverlay)

        XCTAssertFalse(state.resumeAfterOverlay())
        XCTAssertFalse(state.isPausedForOverlay)
        XCTAssertFalse(state.wasCapturingBeforeOverlay)
    }

    func testCanStartCaptureRequiresNoBlockingState() {
        var state = CaptureLifecycleState()

        XCTAssertTrue(state.canStartCapture(isOverlayVisible: false))
        XCTAssertTrue(state.toggleUserPause())
        XCTAssertFalse(state.canStartCapture(isOverlayVisible: false))
        XCTAssertEqual(
            state.blockedStatus(isOverlayVisible: false, includeOverlay: false),
            "Paused (User)"
        )
    }

    /// A second pause event while already paused must not clobber the stored
    /// resume intent — otherwise a duplicate lock/resign notification would
    /// make capture stay off after unlock.
    func testDuplicateSessionPauseDoesNotClobberResumeIntent() {
        var state = CaptureLifecycleState()

        XCTAssertTrue(state.pauseForSession(captureWasActive: true, shouldResumeCapture: true))
        XCTAssertFalse(
            state.pauseForSession(captureWasActive: false, shouldResumeCapture: false),
            "Second pause while paused must be a no-op"
        )

        XCTAssertTrue(state.resumeAfterSession(), "Original resume intent must survive")
    }

    func testDuplicateOverlayPauseDoesNotClobberResumeIntent() {
        var state = CaptureLifecycleState()

        XCTAssertTrue(state.pauseForOverlay(captureWasActive: true, shouldResumeCapture: true))
        XCTAssertFalse(state.pauseForOverlay(captureWasActive: false, shouldResumeCapture: false))

        XCTAssertTrue(state.resumeAfterOverlay())
    }

    func testResumeWithoutMatchingPauseIsANoOp() {
        var state = CaptureLifecycleState()

        XCTAssertFalse(state.resumeAfterSession())
        XCTAssertFalse(state.resumeAfterOverlay())
        XCTAssertTrue(state.canStartCapture(isOverlayVisible: false))
    }

    func testShouldRestartAfterUnexpectedStopRequiresFullyRunningState() {
        var state = CaptureLifecycleState()

        XCTAssertTrue(state.shouldRestartAfterUnexpectedStop(isOverlayVisible: false))
        XCTAssertFalse(state.shouldRestartAfterUnexpectedStop(isOverlayVisible: true))

        _ = state.toggleUserPause()
        XCTAssertFalse(state.shouldRestartAfterUnexpectedStop(isOverlayVisible: false))
        _ = state.toggleUserPause()

        _ = state.pauseForSession(captureWasActive: true, shouldResumeCapture: true)
        XCTAssertFalse(state.shouldRestartAfterUnexpectedStop(isOverlayVisible: false))
        _ = state.resumeAfterSession()

        XCTAssertTrue(state.shouldRestartAfterUnexpectedStop(isOverlayVisible: false))
    }

    func testBlockedStatusCanIgnoreOverlayVisibilityForPostOverlayResume() {
        var state = CaptureLifecycleState()

        XCTAssertTrue(state.pauseForOverlay(captureWasActive: true, shouldResumeCapture: true))

        XCTAssertNil(
            state.blockedStatus(isOverlayVisible: false, includeOverlay: false)
        )
        XCTAssertEqual(
            state.blockedStatus(isOverlayVisible: false),
            "Paused (Overlay)"
        )
    }
}
