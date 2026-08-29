import XCTest
@testable import JustNow

final class CaptureLifecycleStateTests: XCTestCase {
    func testBlockedStatusPrefersUserPauseOverOverlayAndSession() {
        var state = CaptureLifecycleState()

        XCTAssertTrue(state.toggleUserPause())
        XCTAssertFalse(state.pauseForOverlay(captureWasActive: false, shouldResumeCapture: true))
        XCTAssertFalse(state.pauseForSession(captureWasActive: false, shouldResumeCapture: true))
        XCTAssertFalse(state.pauseForLock(captureWasActive: false, shouldResumeCapture: true))
        XCTAssertFalse(
            state.pauseForExternalCapture(captureWasActive: false, shouldResumeCapture: true)
        )

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

    func testPauseAndResumeForLockPreservesResumeIntent() {
        var state = CaptureLifecycleState()

        XCTAssertTrue(
            state.pauseForLock(captureWasActive: true, shouldResumeCapture: true)
        )
        XCTAssertTrue(state.isPausedForLock)
        XCTAssertTrue(state.wasCapturingBeforeLock)
        XCTAssertFalse(state.canStartCapture(isOverlayVisible: false))
        XCTAssertEqual(
            state.blockedStatus(isOverlayVisible: false),
            "Screen Locked"
        )

        XCTAssertTrue(state.resumeAfterLock())
        XCTAssertFalse(state.isPausedForLock)
        XCTAssertFalse(state.wasCapturingBeforeLock)
        XCTAssertTrue(state.canStartCapture(isOverlayVisible: false))
    }

    func testDuplicateLockPauseDoesNotClobberResumeIntent() {
        var state = CaptureLifecycleState()

        XCTAssertTrue(state.pauseForLock(captureWasActive: true, shouldResumeCapture: true))
        XCTAssertFalse(
            state.pauseForLock(captureWasActive: false, shouldResumeCapture: false),
            "Second lock while locked must be a no-op"
        )

        XCTAssertTrue(state.resumeAfterLock(), "Original resume intent must survive")
    }

    func testResumeWithoutMatchingPauseIsANoOp() {
        var state = CaptureLifecycleState()

        XCTAssertFalse(state.resumeAfterSession())
        XCTAssertFalse(state.resumeAfterOverlay())
        XCTAssertFalse(state.resumeAfterLock())
        XCTAssertFalse(state.resumeAfterExternalCapture())
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

        _ = state.pauseForLock(captureWasActive: true, shouldResumeCapture: true)
        XCTAssertFalse(state.shouldRestartAfterUnexpectedStop(isOverlayVisible: false))
        _ = state.resumeAfterLock()

        _ = state.pauseForExternalCapture(captureWasActive: true, shouldResumeCapture: true)
        XCTAssertFalse(state.shouldRestartAfterUnexpectedStop(isOverlayVisible: false))
        _ = state.resumeAfterExternalCapture()

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

    func testPauseAndResumeForExternalCapturePreservesResumeIntent() {
        var state = CaptureLifecycleState()

        XCTAssertTrue(
            state.pauseForExternalCapture(captureWasActive: true, shouldResumeCapture: true)
        )
        XCTAssertTrue(state.isPausedForExternalCapture)
        XCTAssertTrue(state.wasCapturingBeforeExternalCapture)
        XCTAssertFalse(state.canStartCapture(isOverlayVisible: false))
        XCTAssertEqual(
            state.blockedStatus(isOverlayVisible: false),
            CaptureStatusCopy.screenInUse
        )

        XCTAssertTrue(state.resumeAfterExternalCapture())
        XCTAssertFalse(state.isPausedForExternalCapture)
        XCTAssertFalse(state.wasCapturingBeforeExternalCapture)
        XCTAssertTrue(state.canStartCapture(isOverlayVisible: false))
    }

    func testDuplicateExternalCapturePauseDoesNotClobberResumeIntent() {
        var state = CaptureLifecycleState()

        XCTAssertTrue(
            state.pauseForExternalCapture(captureWasActive: true, shouldResumeCapture: true)
        )
        XCTAssertFalse(
            state.pauseForExternalCapture(captureWasActive: false, shouldResumeCapture: false),
            "Second pause while already paused must be a no-op"
        )

        XCTAssertTrue(state.resumeAfterExternalCapture(), "Original resume intent must survive")
    }

    func testUserPauseWinsOverExternalCaptureBlockedStatus() {
        var state = CaptureLifecycleState()

        XCTAssertTrue(
            state.pauseForExternalCapture(captureWasActive: true, shouldResumeCapture: true)
        )
        XCTAssertTrue(state.toggleUserPause())

        XCTAssertEqual(
            state.blockedStatus(isOverlayVisible: false),
            "Paused (User)"
        )
        XCTAssertFalse(state.canStartCapture(isOverlayVisible: false))
    }
}
