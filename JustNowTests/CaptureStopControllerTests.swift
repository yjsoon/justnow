import XCTest
@testable import JustNow

@MainActor
final class CaptureStopControllerTests: XCTestCase {
    func testPerformStopUpdatesStatusStopsCaptureAndEndsForegroundActivity() async {
        let recorder = CaptureStopControllerRecorder()
        let controller = CaptureStopController(
            updateStatus: { status in
                recorder.recordStatus(status)
            },
            stopCapture: {
                recorder.recordStopCapture()
            },
            endForegroundActivity: {
                recorder.recordEndForegroundActivity()
            }
        )

        await controller.performStop(CaptureStopRequest(status: "Paused (Overlay)"))

        XCTAssertEqual(
            recorder.events,
            [
                "status:Paused (Overlay)",
                "stopCapture",
                "endForegroundActivity"
            ]
        )
    }

    func testPerformStopLogsOptionalMessageAfterStopping() async {
        let recorder = CaptureStopControllerRecorder()
        let controller = CaptureStopController(
            updateStatus: { status in
                recorder.recordStatus(status)
            },
            stopCapture: {
                recorder.recordStopCapture()
            },
            endForegroundActivity: {
                recorder.recordEndForegroundActivity()
            },
            logger: { message in
                recorder.recordLog(message)
            }
        )

        await controller.performStop(
            CaptureStopRequest(
                status: "Sleeping...",
                logMessage: "Capture paused for system sleep"
            )
        )

        XCTAssertEqual(
            recorder.events,
            [
                "status:Sleeping...",
                "stopCapture",
                "endForegroundActivity",
                "log:Capture paused for system sleep"
            ]
        )
    }
}

@MainActor
private final class CaptureStopControllerRecorder {
    private(set) var events: [String] = []

    func recordStatus(_ status: String) {
        events.append("status:\(status)")
    }

    func recordStopCapture() {
        events.append("stopCapture")
    }

    func recordEndForegroundActivity() {
        events.append("endForegroundActivity")
    }

    func recordLog(_ message: String) {
        events.append("log:\(message)")
    }
}
