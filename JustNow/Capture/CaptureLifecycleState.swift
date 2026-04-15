struct CaptureLifecycleState {
    private(set) var isUserPaused = false
    private(set) var wasCapturingBeforeOverlay = false
    private(set) var isPausedForOverlay = false
    private(set) var wasCapturingBeforeSession = false
    private(set) var isPausedForSession = false

    func canStartCapture(isOverlayVisible: Bool) -> Bool {
        !isUserPaused && !isPausedForOverlay && !isPausedForSession && !isOverlayVisible
    }

    func blockedStatus(isOverlayVisible: Bool, includeOverlay: Bool = true) -> String? {
        if isUserPaused {
            return "Paused (User)"
        }
        if includeOverlay, isPausedForOverlay || isOverlayVisible {
            return "Paused (Overlay)"
        }
        if isPausedForSession {
            return "Session Inactive"
        }
        return nil
    }

    func shouldRestartAfterUnexpectedStop(isOverlayVisible: Bool) -> Bool {
        !isOverlayVisible && !isPausedForOverlay && !isPausedForSession && !isUserPaused
    }

    mutating func toggleUserPause() -> Bool {
        isUserPaused.toggle()
        return isUserPaused
    }

    mutating func pauseForSession(captureWasActive: Bool, shouldResumeCapture: Bool) -> Bool {
        guard !isPausedForSession else { return false }
        isPausedForSession = true
        wasCapturingBeforeSession = shouldResumeCapture
        return captureWasActive
    }

    mutating func resumeAfterSession() -> Bool {
        guard isPausedForSession else { return false }
        isPausedForSession = false
        let shouldResumeCapture = wasCapturingBeforeSession
        wasCapturingBeforeSession = false
        return shouldResumeCapture
    }

    mutating func pauseForOverlay(captureWasActive: Bool, shouldResumeCapture: Bool) -> Bool {
        guard !isPausedForOverlay else { return false }
        isPausedForOverlay = true
        wasCapturingBeforeOverlay = shouldResumeCapture
        return captureWasActive
    }

    mutating func resumeAfterOverlay() -> Bool {
        guard isPausedForOverlay else { return false }
        isPausedForOverlay = false
        let shouldResumeCapture = wasCapturingBeforeOverlay
        wasCapturingBeforeOverlay = false
        return shouldResumeCapture
    }
}
