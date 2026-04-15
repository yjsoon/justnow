import Foundation

struct CaptureEventContext {
    let hasCaptureManager: Bool
    let isCapturing: Bool
    let isSetupCaptureInProgress: Bool
    let hasPendingStart: Bool
    let isOverlayVisible: Bool
}

@MainActor
final class CaptureEventController {
    private var lifecycle = CaptureLifecycleState()
    private let context: () -> CaptureEventContext
    private let scheduleStart: (CaptureStartRequest) -> Void
    private let cancelPendingStart: () -> Void
    private let scheduleStop: (CaptureStopRequest) -> Void
    private let updateStatus: (String) -> Void
    private let enableBlackFrameFilter: (TimeInterval) -> Void
    private let endForegroundActivity: () -> Void
    private let updatePauseMenu: (Bool) -> Void
    private let logger: (String) -> Void

    init(
        context: @escaping () -> CaptureEventContext,
        scheduleStart: @escaping (CaptureStartRequest) -> Void,
        cancelPendingStart: @escaping () -> Void,
        scheduleStop: @escaping (CaptureStopRequest) -> Void,
        updateStatus: @escaping (String) -> Void,
        enableBlackFrameFilter: @escaping (TimeInterval) -> Void,
        endForegroundActivity: @escaping () -> Void,
        updatePauseMenu: @escaping (Bool) -> Void,
        logger: @escaping (String) -> Void = { print($0) }
    ) {
        self.context = context
        self.scheduleStart = scheduleStart
        self.cancelPendingStart = cancelPendingStart
        self.scheduleStop = scheduleStop
        self.updateStatus = updateStatus
        self.enableBlackFrameFilter = enableBlackFrameFilter
        self.endForegroundActivity = endForegroundActivity
        self.updatePauseMenu = updatePauseMenu
        self.logger = logger
    }

    var isUserPaused: Bool {
        lifecycle.isUserPaused
    }

    func canStartCapture() -> Bool {
        lifecycle.canStartCapture(isOverlayVisible: context().isOverlayVisible)
    }

    func blockedStatus(includeOverlay: Bool = true) -> String? {
        lifecycle.blockedStatus(
            isOverlayVisible: context().isOverlayVisible,
            includeOverlay: includeOverlay
        )
    }

    func handleSleep() {
        cancelPendingStart()
        scheduleStop(
            CaptureStopRequest(
                status: "Sleeping...",
                logMessage: "Capture paused for system sleep"
            )
        )
    }

    func handleWake() {
        enableBlackFrameFilter(5)
        scheduleResume(reason: "system wake")
    }

    func handleScreenSleep() {
        cancelPendingStart()
        scheduleStop(
            CaptureStopRequest(
                status: "Screen Off",
                logMessage: "Capture paused for screen sleep"
            )
        )
    }

    func handleScreenWake() {
        enableBlackFrameFilter(5)
        scheduleResume(reason: "screen wake")
    }

    func handleSessionResignActive() {
        let current = context()
        let shouldResumeCaptureAfterSession =
            current.isCapturing
            || current.isSetupCaptureInProgress
            || current.hasPendingStart
            || (lifecycle.isPausedForOverlay && lifecycle.wasCapturingBeforeOverlay)
        let shouldStopCapture = lifecycle.pauseForSession(
            captureWasActive: current.isCapturing,
            shouldResumeCapture: shouldResumeCaptureAfterSession
        )
        cancelPendingStart()

        guard shouldStopCapture else { return }
        scheduleStop(CaptureStopRequest(status: "Session Inactive"))
    }

    func handleSessionBecomeActive() {
        guard lifecycle.resumeAfterSession() else { return }

        enableBlackFrameFilter(5)
        scheduleResume(reason: "session active")
    }

    func handleUnexpectedStop() {
        guard lifecycle.shouldRestartAfterUnexpectedStop(isOverlayVisible: context().isOverlayVisible) else { return }
        logger("Capture stopped unexpectedly, attempting restart...")
        endForegroundActivity()
        scheduleStart(
            CaptureStartRequest(
                status: "Restarting...",
                initialDelay: .seconds(2),
                attempt: CaptureStartAttempt(
                    successMessage: "Capture restarted successfully",
                    failurePrefix: "Failed to restart capture",
                    failureStatus: "Stopped"
                )
            )
        )
    }

    func toggleCapturePause() {
        let isUserPaused = lifecycle.toggleUserPause()
        updatePauseMenu(isUserPaused)

        let current = context()
        guard current.hasCaptureManager else {
            updateStatus(isUserPaused ? "Paused (User)" : "Starting...")
            return
        }

        if isUserPaused {
            cancelPendingStart()
            scheduleStop(CaptureStopRequest(status: "Paused (User)"))
            return
        }

        enableBlackFrameFilter(2)
        scheduleResume(reason: "manual resume")
    }

    func handleOverlayVisibilityChanged(isVisible: Bool) {
        if isVisible {
            pauseCaptureForOverlay()
        } else {
            resumeCaptureAfterOverlay()
        }
    }

    private func pauseCaptureForOverlay() {
        let current = context()
        let shouldResumeCaptureAfterOverlay =
            current.isCapturing
            || current.isSetupCaptureInProgress
            || current.hasPendingStart
            || (lifecycle.isPausedForSession && lifecycle.wasCapturingBeforeSession)
        let shouldStopCapture = lifecycle.pauseForOverlay(
            captureWasActive: current.isCapturing,
            shouldResumeCapture: shouldResumeCaptureAfterOverlay
        )
        cancelPendingStart()

        guard shouldStopCapture else { return }
        scheduleStop(CaptureStopRequest(status: "Paused (Overlay)"))
    }

    private func resumeCaptureAfterOverlay() {
        guard lifecycle.resumeAfterOverlay() else { return }

        let current = context()
        if current.isSetupCaptureInProgress {
            cancelPendingStart()
            updateStatus(blockedStatus(includeOverlay: false) ?? "Resuming...")
            return
        }

        scheduleStart(
            CaptureStartRequest(
                status: "Resuming...",
                includeOverlayInBlockedStatus: false,
                attempt: CaptureStartAttempt(
                    successMessage: "Capture resumed after overlay",
                    failurePrefix: "Failed to resume capture after overlay",
                    failureStatus: "Error"
                )
            )
        )
    }

    private func scheduleResume(reason: String) {
        let current = context()
        if current.isSetupCaptureInProgress {
            cancelPendingStart()
            updateStatus(blockedStatus() ?? "Resuming...")
            return
        }

        scheduleStart(
            CaptureStartRequest(
                status: "Resuming...",
                initialDelay: .seconds(2),
                attempt: CaptureStartAttempt(
                    successMessage: "Capture resumed after \(reason)",
                    failurePrefix: "Failed to resume capture after \(reason)",
                    failureStatus: "Error"
                ),
                retry: CaptureStartRetryPolicy(
                    delay: .seconds(3),
                    attempt: CaptureStartAttempt(
                        successMessage: "Capture resumed on retry",
                        failurePrefix: "Retry also failed",
                        failureStatus: "Failed"
                    )
                )
            )
        )
    }
}
