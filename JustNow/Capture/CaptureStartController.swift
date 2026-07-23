import Foundation

struct CaptureStartAttempt {
    let successMessage: String
    let failurePrefix: String
    let failureStatus: String
}

struct CaptureStartRetryPolicy {
    let delay: Duration
    let attempt: CaptureStartAttempt
}

enum CaptureStartResult: Equatable {
    case started
    /// Recovery is already owned by another scheduler, so this attempt must
    /// not consume the generic delayed-retry policy.
    case deferred
    case failed
}

struct CaptureStartRequest {
    let status: String
    let includeOverlayInBlockedStatus: Bool
    let initialDelay: Duration?
    let attempt: CaptureStartAttempt
    let retry: CaptureStartRetryPolicy?

    init(
        status: String,
        includeOverlayInBlockedStatus: Bool = true,
        initialDelay: Duration? = nil,
        attempt: CaptureStartAttempt,
        retry: CaptureStartRetryPolicy? = nil
    ) {
        self.status = status
        self.includeOverlayInBlockedStatus = includeOverlayInBlockedStatus
        self.initialDelay = initialDelay
        self.attempt = attempt
        self.retry = retry
    }
}

@MainActor
final class CaptureStartController {
    private let sleep: (Duration) async -> Void
    private var pendingStartTask: Task<Void, Never>?
    private var pendingStartGeneration = 0
    private var isStartDeferred = false
    private var deferredCompletionGeneration = 0

    init(
        sleep: @escaping (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.sleep = sleep
    }

    var hasPendingStart: Bool {
        pendingStartTask != nil || isStartDeferred
    }

    func cancelPendingStart() {
        pendingStartGeneration += 1
        pendingStartTask?.cancel()
        pendingStartTask = nil
        isStartDeferred = false
    }

    func completeDeferredStart() {
        deferredCompletionGeneration += 1
        isStartDeferred = false
    }

    func scheduleStart(
        request: CaptureStartRequest,
        canStartCapture: @escaping () -> Bool,
        blockedStatus: @escaping (Bool) -> String?,
        updateStatus: @escaping (String) -> Void,
        startCapture: @escaping (CaptureStartAttempt) async -> CaptureStartResult
    ) {
        cancelPendingStart()
        let generation = pendingStartGeneration

        pendingStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == self.pendingStartGeneration {
                    self.pendingStartTask = nil
                }
            }

            guard canStartCapture() else {
                if let blockedStatus = blockedStatus(request.includeOverlayInBlockedStatus) {
                    updateStatus(blockedStatus)
                }
                return
            }

            updateStatus(request.status)

            if let initialDelay = request.initialDelay {
                await sleep(initialDelay)
            }

            guard !Task.isCancelled,
                  generation == self.pendingStartGeneration,
                  canStartCapture() else {
                return
            }

            let initialCompletionGeneration = self.deferredCompletionGeneration
            let result = await startCapture(request.attempt)
            guard !Task.isCancelled,
                  generation == self.pendingStartGeneration else {
                return
            }
            if result == .deferred {
                // The coordinator owns the actual cooldown timer, but the app
                // lifecycle must still see pending recovery so overlay/session
                // transitions can stop and cancel that coordinator work.
                if initialCompletionGeneration == self.deferredCompletionGeneration {
                    self.isStartDeferred = true
                }
                return
            }
            guard result == .failed, let retry = request.retry else { return }

            await sleep(retry.delay)

            guard !Task.isCancelled,
                  generation == self.pendingStartGeneration,
                  canStartCapture() else {
                return
            }

            let retryCompletionGeneration = self.deferredCompletionGeneration
            let retryResult = await startCapture(retry.attempt)
            guard !Task.isCancelled,
                  generation == self.pendingStartGeneration else {
                return
            }
            if retryResult == .deferred,
               retryCompletionGeneration == self.deferredCompletionGeneration {
                self.isStartDeferred = true
            }
        }
    }
}
