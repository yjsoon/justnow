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

    init(
        sleep: @escaping (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.sleep = sleep
    }

    var hasPendingStart: Bool {
        pendingStartTask != nil
    }

    func cancelPendingStart() {
        pendingStartGeneration += 1
        pendingStartTask?.cancel()
        pendingStartTask = nil
    }

    func scheduleStart(
        request: CaptureStartRequest,
        canStartCapture: @escaping () -> Bool,
        blockedStatus: @escaping (Bool) -> String?,
        updateStatus: @escaping (String) -> Void,
        startCapture: @escaping (CaptureStartAttempt) async -> Bool
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

            let didStart = await startCapture(request.attempt)
            guard !didStart, let retry = request.retry else { return }

            await sleep(retry.delay)

            guard !Task.isCancelled,
                  generation == self.pendingStartGeneration,
                  canStartCapture() else {
                return
            }

            _ = await startCapture(retry.attempt)
        }
    }
}
