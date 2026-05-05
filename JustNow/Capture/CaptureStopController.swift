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
        }
    }

    func scheduleStop(_ request: CaptureStopRequest) {
        Task { @MainActor [weak self] in
            await self?.performStop(request)
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
