import Foundation
import os.log

private let captureLogger = Logger(subsystem: "sg.tk.JustNow", category: "Capture")

struct CaptureStopRequest {
    let status: String
    let logMessage: String?
    let sessionEndReason: CaptureSessionEndReason

    init(
        status: String,
        logMessage: String? = nil,
        sessionEndReason: CaptureSessionEndReason = .paused
    ) {
        self.status = status
        self.logMessage = logMessage
        self.sessionEndReason = sessionEndReason
    }
}

@MainActor
final class CaptureStopController {
    private let updateStatus: (String) -> Void
    private let stopCapture: (CaptureSessionEndReason) async -> Void
    private let endForegroundActivity: () -> Void
    private let logger: (String) -> Void
    private var pendingStopTask: Task<Void, Never>?
    private var stopGeneration = 0

    init(
        updateStatus: @escaping (String) -> Void,
        stopCapture: @escaping (CaptureSessionEndReason) async -> Void,
        endForegroundActivity: @escaping () -> Void,
        logger: ((String) -> Void)? = nil
    ) {
        self.updateStatus = updateStatus
        self.stopCapture = stopCapture
        self.endForegroundActivity = endForegroundActivity
        self.logger = logger ?? { message in
            captureLogger.info("\(message, privacy: .public)")
            DiagnosticsLog.shared.log("Capture", message)
        }
    }

    func scheduleStop(
        _ request: CaptureStopRequest,
        afterStop: @escaping () -> Void = {}
    ) {
        stopGeneration += 1
        let generation = stopGeneration
        let previousStopTask = pendingStopTask
        pendingStopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Preserve lifecycle intent order even when several system events
            // enqueue sibling unstructured tasks in the same run-loop turn.
            await previousStopTask?.value
            await self.performStop(request)
            afterStop()
            if generation == self.stopGeneration {
                self.pendingStopTask = nil
            }
        }
    }

    func waitForPendingStop() async {
        while let pendingStopTask {
            await pendingStopTask.value
        }
    }

    func performStop(_ request: CaptureStopRequest) async {
        updateStatus(request.status)
        await stopCapture(request.sessionEndReason)
        endForegroundActivity()

        if let logMessage = request.logMessage {
            logger(logMessage)
        }
    }
}
