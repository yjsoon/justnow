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

    func testWaitForPendingStopOrdersLaterStartAfterStopCompletion() async {
        let stopGate = CaptureStopControllerTestGate()
        var events: [String] = []
        let controller = CaptureStopController(
            updateStatus: { _ in },
            stopCapture: {
                events.append("stop-enter")
                await stopGate.wait()
                events.append("stop-exit")
            },
            endForegroundActivity: {}
        )

        controller.scheduleStop(CaptureStopRequest(status: "Stopping"))
        await waitUntil { events == ["stop-enter"] }

        let laterStart = Task { @MainActor in
            await controller.waitForPendingStop()
            events.append("start")
        }
        await Task.yield()
        XCTAssertEqual(events, ["stop-enter"])

        await stopGate.resume()
        await laterStart.value
        XCTAssertEqual(events, ["stop-enter", "stop-exit", "start"])
    }

    func testWaitForPendingStopIncludesEveryQueuedStop() async {
        let firstStopGate = CaptureStopControllerTestGate()
        var events: [String] = []
        var stopCount = 0
        let controller = CaptureStopController(
            updateStatus: { _ in },
            stopCapture: {
                stopCount += 1
                events.append("stop-\(stopCount)-enter")
                if stopCount == 1 {
                    await firstStopGate.wait()
                }
                events.append("stop-\(stopCount)-exit")
            },
            endForegroundActivity: {}
        )

        controller.scheduleStop(CaptureStopRequest(status: "First"))
        await waitUntil { events == ["stop-1-enter"] }
        controller.scheduleStop(CaptureStopRequest(status: "Second"))

        let laterStart = Task { @MainActor in
            await controller.waitForPendingStop()
            events.append("start")
        }
        await Task.yield()
        XCTAssertEqual(events, ["stop-1-enter"])

        await firstStopGate.resume()
        await laterStart.value
        XCTAssertEqual(
            events,
            ["stop-1-enter", "stop-1-exit", "stop-2-enter", "stop-2-exit", "start"]
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
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

private actor CaptureStopControllerTestGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
