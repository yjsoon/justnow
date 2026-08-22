import XCTest
@testable import JustNow

@MainActor
final class CaptureEventControllerTests: XCTestCase {
    func testHandleSessionResignActiveCancelsPendingStartAndSchedulesStop() {
        let recorder = CaptureEventControllerRecorder(
            context: CaptureEventContext(
                hasCaptureManager: true,
                isCapturing: true,
                isSetupCaptureInProgress: false,
                hasPendingStart: true,
                isOverlayVisible: false
            )
        )
        let controller = recorder.makeController()

        controller.handleSessionResignActive()

        XCTAssertEqual(
            recorder.events,
            [
                "cancelPendingStart",
                "stop:Session Inactive"
            ]
        )
    }

    func testHandleSessionBecomeActiveSchedulesResumeAfterPriorPause() {
        let recorder = CaptureEventControllerRecorder(
            context: CaptureEventContext(
                hasCaptureManager: true,
                isCapturing: true,
                isSetupCaptureInProgress: false,
                hasPendingStart: false,
                isOverlayVisible: false
            )
        )
        let controller = recorder.makeController()

        controller.handleSessionResignActive()
        recorder.clearEvents()
        recorder.context = CaptureEventContext(
            hasCaptureManager: true,
            isCapturing: false,
            isSetupCaptureInProgress: false,
            hasPendingStart: false,
            isOverlayVisible: false
        )

        controller.handleSessionBecomeActive()

        XCTAssertEqual(recorder.events, ["filter:5.0", "start:Resuming..."])
        XCTAssertEqual(recorder.startRequests.count, 1)
        XCTAssertEqual(recorder.startRequests[0].attempt.successMessage, "Capture resumed after session active")
        XCTAssertEqual(recorder.startRequests[0].retry?.delay, .seconds(3))
    }

    func testSessionResignStopsDeferredCoordinatorRecovery() {
        let recorder = CaptureEventControllerRecorder(
            context: CaptureEventContext(
                hasCaptureManager: true,
                isCapturing: false,
                isSetupCaptureInProgress: false,
                hasPendingStart: true,
                isOverlayVisible: false
            )
        )
        let controller = recorder.makeController()

        controller.handleSessionResignActive()

        XCTAssertEqual(
            recorder.events,
            ["cancelPendingStart", "stop:Session Inactive"]
        )
    }

    func testOverlayPauseStopsDeferredCoordinatorRecovery() {
        let recorder = CaptureEventControllerRecorder(
            context: CaptureEventContext(
                hasCaptureManager: true,
                isCapturing: false,
                isSetupCaptureInProgress: false,
                hasPendingStart: true,
                isOverlayVisible: true
            )
        )
        let controller = recorder.makeController()

        controller.handleOverlayVisibilityChanged(isVisible: true)

        XCTAssertEqual(
            recorder.events,
            ["cancelPendingStart", "stop:Paused (Overlay)"]
        )
    }

    func testOverlayPauseStopsLaunchSetupRecovery() {
        let recorder = CaptureEventControllerRecorder(
            context: CaptureEventContext(
                hasCaptureManager: false,
                isCapturing: false,
                isSetupCaptureInProgress: true,
                hasPendingStart: false,
                isOverlayVisible: true
            )
        )
        let controller = recorder.makeController()

        controller.handleOverlayVisibilityChanged(isVisible: true)

        XCTAssertEqual(
            recorder.events,
            ["cancelPendingStart", "stop:Paused (Overlay)"]
        )
    }

    func testCorrectiveStopReasonPreservesOverlayAndSessionBlockers() {
        let overlayRecorder = CaptureEventControllerRecorder(
            context: CaptureEventContext(
                hasCaptureManager: true,
                isCapturing: true,
                isSetupCaptureInProgress: false,
                hasPendingStart: false,
                isOverlayVisible: true
            )
        )
        let overlayController = overlayRecorder.makeController()
        overlayController.handleOverlayVisibilityChanged(isVisible: true)
        XCTAssertEqual(overlayController.blockedSessionEndReason(), .overlay)

        let sessionRecorder = CaptureEventControllerRecorder(
            context: CaptureEventContext(
                hasCaptureManager: true,
                isCapturing: true,
                isSetupCaptureInProgress: false,
                hasPendingStart: false,
                isOverlayVisible: false
            )
        )
        let sessionController = sessionRecorder.makeController()
        sessionController.handleSessionResignActive()
        XCTAssertEqual(sessionController.blockedSessionEndReason(), .sessionInactive)
    }

    func testWakePreservesResumeIntentWhileLaunchSetupIsInProgress() {
        let recorder = CaptureEventControllerRecorder(
            context: CaptureEventContext(
                hasCaptureManager: false,
                isCapturing: false,
                isSetupCaptureInProgress: true,
                hasPendingStart: false,
                isOverlayVisible: false
            )
        )
        let controller = recorder.makeController()

        controller.handleWake()

        XCTAssertEqual(recorder.events, ["filter:5.0", "start:Resuming..."])
        XCTAssertEqual(recorder.startRequests.count, 1)
    }

    func testToggleCapturePauseWithoutCaptureManagerUpdatesPauseMenuAndStatus() {
        let recorder = CaptureEventControllerRecorder(
            context: CaptureEventContext(
                hasCaptureManager: false,
                isCapturing: false,
                isSetupCaptureInProgress: false,
                hasPendingStart: false,
                isOverlayVisible: false
            )
        )
        let controller = recorder.makeController()

        controller.toggleCapturePause()
        controller.toggleCapturePause()

        XCTAssertEqual(
            recorder.events,
            [
                "pauseMenu:true",
                "status:Paused (User)",
                "pauseMenu:false",
                "status:Starting..."
            ]
        )
    }

    func testHandleScreenLockCancelsPendingStartAndSchedulesStop() {
        let recorder = CaptureEventControllerRecorder(
            context: CaptureEventContext(
                hasCaptureManager: true,
                isCapturing: true,
                isSetupCaptureInProgress: false,
                hasPendingStart: true,
                isOverlayVisible: false
            )
        )
        let controller = recorder.makeController()

        controller.handleScreenLock()

        XCTAssertEqual(
            recorder.events,
            [
                "cancelPendingStart",
                "stop:Screen Locked"
            ]
        )
    }

    func testScreenLockBlocksStartUntilUnlock() {
        let recorder = CaptureEventControllerRecorder(
            context: CaptureEventContext(
                hasCaptureManager: true,
                isCapturing: true,
                isSetupCaptureInProgress: false,
                hasPendingStart: false,
                isOverlayVisible: false
            )
        )
        let controller = recorder.makeController()

        controller.handleScreenLock()
        XCTAssertFalse(controller.canStartCapture())
        XCTAssertEqual(controller.blockedStatus(), "Screen Locked")
        XCTAssertEqual(controller.blockedSessionEndReason(), .screenLock)

        recorder.clearEvents()
        recorder.context = CaptureEventContext(
            hasCaptureManager: true,
            isCapturing: false,
            isSetupCaptureInProgress: false,
            hasPendingStart: false,
            isOverlayVisible: false
        )
        controller.handleWake()
        XCTAssertFalse(controller.canStartCapture())
        XCTAssertEqual(controller.blockedStatus(), "Screen Locked")
        XCTAssertEqual(recorder.events, ["filter:5.0", "start:Resuming..."])

        recorder.clearEvents()
        controller.handleScreenUnlock()
        XCTAssertTrue(controller.canStartCapture())
        XCTAssertEqual(recorder.events, ["filter:5.0", "start:Resuming..."])
    }

    func testLockThenOverlayResumesWhenOverlayCloses() {
        let recorder = CaptureEventControllerRecorder(
            context: CaptureEventContext(
                hasCaptureManager: true,
                isCapturing: true,
                isSetupCaptureInProgress: false,
                hasPendingStart: false,
                isOverlayVisible: false
            )
        )
        let controller = recorder.makeController()

        controller.handleScreenLock()
        recorder.context = CaptureEventContext(
            hasCaptureManager: true,
            isCapturing: false,
            isSetupCaptureInProgress: false,
            hasPendingStart: false,
            isOverlayVisible: true
        )
        controller.handleOverlayVisibilityChanged(isVisible: true)

        recorder.clearEvents()
        controller.handleScreenUnlock()
        XCTAssertFalse(controller.canStartCapture())
        XCTAssertEqual(controller.blockedStatus(), "Paused (Overlay)")

        recorder.clearEvents()
        recorder.context = CaptureEventContext(
            hasCaptureManager: true,
            isCapturing: false,
            isSetupCaptureInProgress: false,
            hasPendingStart: false,
            isOverlayVisible: false
        )
        controller.handleOverlayVisibilityChanged(isVisible: false)

        XCTAssertEqual(recorder.events, ["start:Resuming..."])
        XCTAssertEqual(
            recorder.startRequests.last?.attempt.successMessage,
            "Capture resumed after overlay"
        )
    }

    func testLockThenSessionResignResumesWhenSessionBecomesActive() {
        let recorder = CaptureEventControllerRecorder(
            context: CaptureEventContext(
                hasCaptureManager: true,
                isCapturing: true,
                isSetupCaptureInProgress: false,
                hasPendingStart: false,
                isOverlayVisible: false
            )
        )
        let controller = recorder.makeController()

        controller.handleScreenLock()
        recorder.context = CaptureEventContext(
            hasCaptureManager: true,
            isCapturing: false,
            isSetupCaptureInProgress: false,
            hasPendingStart: false,
            isOverlayVisible: false
        )
        controller.handleSessionResignActive()

        recorder.clearEvents()
        controller.handleScreenUnlock()
        XCTAssertFalse(controller.canStartCapture())
        XCTAssertEqual(controller.blockedStatus(), "Session Inactive")

        recorder.clearEvents()
        controller.handleSessionBecomeActive()

        XCTAssertEqual(recorder.events, ["filter:5.0", "start:Resuming..."])
        XCTAssertEqual(
            recorder.startRequests.last?.attempt.successMessage,
            "Capture resumed after session active"
        )
    }

    func testRetryResumeUntilUnlockedKeepsLockedStatus() {
        let recorder = CaptureEventControllerRecorder(
            context: CaptureEventContext(
                hasCaptureManager: true,
                isCapturing: false,
                isSetupCaptureInProgress: false,
                hasPendingStart: false,
                isOverlayVisible: false
            )
        )
        let controller = recorder.makeController()

        controller.retryResumeUntilUnlocked()

        XCTAssertEqual(recorder.events, ["start:Screen Locked"])
        XCTAssertEqual(recorder.startRequests.count, 1)
        XCTAssertEqual(recorder.startRequests[0].status, "Screen Locked")
        XCTAssertEqual(recorder.startRequests[0].initialDelay, .seconds(2))
        XCTAssertNil(recorder.startRequests[0].retry)
        XCTAssertEqual(
            recorder.startRequests[0].attempt.failureStatus,
            "Screen Locked"
        )
    }

    func testHandleScreenUnlockSchedulesResumeWithRetry() {
        let recorder = CaptureEventControllerRecorder(
            context: CaptureEventContext(
                hasCaptureManager: true,
                isCapturing: false,
                isSetupCaptureInProgress: false,
                hasPendingStart: false,
                isOverlayVisible: false
            )
        )
        let controller = recorder.makeController()

        controller.handleScreenUnlock()

        XCTAssertEqual(recorder.events, ["filter:5.0", "start:Resuming..."])
        XCTAssertEqual(recorder.startRequests.count, 1)
        XCTAssertEqual(recorder.startRequests[0].attempt.successMessage, "Capture resumed after screen unlock")
        XCTAssertEqual(recorder.startRequests[0].retry?.delay, .seconds(3))
    }

    func testHandleUnexpectedStopRestartsAndEndsForegroundActivity() {
        let recorder = CaptureEventControllerRecorder(
            context: CaptureEventContext(
                hasCaptureManager: true,
                isCapturing: false,
                isSetupCaptureInProgress: false,
                hasPendingStart: false,
                isOverlayVisible: false
            )
        )
        let controller = recorder.makeController()

        controller.handleUnexpectedStop()

        XCTAssertEqual(
            recorder.events,
            [
                "log:Capture stopped unexpectedly, attempting restart...",
                "endForegroundActivity",
                "start:Restarting..."
            ]
        )
        XCTAssertEqual(recorder.startRequests[0].attempt.successMessage, "Capture restarted successfully")
    }
}

@MainActor
private final class CaptureEventControllerRecorder {
    var context: CaptureEventContext
    private(set) var events: [String] = []
    private(set) var startRequests: [CaptureStartRequest] = []
    private var retainedController: CaptureEventController?

    init(context: CaptureEventContext) {
        self.context = context
    }

    func clearEvents() {
        events.removeAll()
    }

    func makeController() -> CaptureEventController {
        let controller = CaptureEventController(
            context: { self.context },
            scheduleStart: { request in
                self.events.append("start:\(request.status)")
                self.startRequests.append(request)
            },
            cancelPendingStart: {
                self.events.append("cancelPendingStart")
            },
            scheduleStop: { request in
                self.events.append("stop:\(request.status)")
            },
            updateStatus: { status in
                self.events.append("status:\(status)")
            },
            enableBlackFrameFilter: { frameCount in
                self.events.append("filter:\(frameCount)")
            },
            endForegroundActivity: {
                self.events.append("endForegroundActivity")
            },
            updatePauseMenu: { isPaused in
                self.events.append("pauseMenu:\(isPaused)")
            },
            logger: { message in
                self.events.append("log:\(message)")
            }
        )
        retainedController = controller
        return controller
    }
}
