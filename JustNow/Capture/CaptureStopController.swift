import Foundation
import os.log

private let captureLogger = Logger(subsystem: "sg.tk.JustNow", category: "Capture")

struct CaptureStopRequest {
    let status: String
    let logMessage: String?

    init(status: String, logMessage: String? = nil) {
        self.status = status
        self.logMessage = logMessage
    }
}

@MainActor
final class CaptureStopController {
    private let updateStatus: (String) -> Void
    private let stopCapture: () async -> Void
    private let endForegroundActivity: () -> Void
    private let logger: (String) -> Void
    private var pendingStopTask: Task<Void, Never>?
    private var stopGeneration = 0

    init(
        updateStatus: @escaping (String) -> Void,
        stopCapture: @escaping () async -> Void,
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
        pendingStopTask = Task { @MainActor [weak self] in
            guard let self else { return }
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
        await stopCapture()
        endForegroundActivity()

        if let logMessage = request.logMessage {
            logger(logMessage)
        }
    }
}
