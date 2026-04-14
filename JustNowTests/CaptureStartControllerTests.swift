import XCTest
@testable import JustNow

@MainActor
final class CaptureStartControllerTests: XCTestCase {
    func testScheduleStartUsesBlockedStatusWithoutStartingCapture() async {
        let controller = CaptureStartController()
        var statuses: [String] = []
        var startAttempts = 0

        controller.scheduleStart(
            request: CaptureStartRequest(
                status: "Resuming...",
                attempt: CaptureStartAttempt(
                    successMessage: "started",
                    failurePrefix: "failed",
                    failureStatus: "Error"
                )
            ),
            canStartCapture: { false },
            blockedStatus: { includeOverlay in
                includeOverlay ? "Paused (Overlay)" : nil
            },
            updateStatus: { statuses.append($0) },
            startCapture: { _ in
                startAttempts += 1
                return true
            }
        )

        await settleScheduledTasks()

        XCTAssertEqual(statuses, ["Paused (Overlay)"])
        XCTAssertEqual(startAttempts, 0)
        XCTAssertFalse(controller.hasPendingStart)
    }

    func testScheduleStartRetriesAfterInitialFailure() async {
        let sleeper = CaptureStartControllerSleepProbe()
        let controller = CaptureStartController(
            sleep: { duration in
                await sleeper.sleep(for: duration)
            }
        )
        var statuses: [String] = []
        var startAttempts: [CaptureStartAttempt] = []

        controller.scheduleStart(
            request: CaptureStartRequest(
                status: "Restarting...",
                attempt: CaptureStartAttempt(
                    successMessage: "first",
                    failurePrefix: "first failed",
                    failureStatus: "Stopped"
                ),
                retry: CaptureStartRetryPolicy(
                    delay: .seconds(3),
                    attempt: CaptureStartAttempt(
                        successMessage: "second",
                        failurePrefix: "second failed",
                        failureStatus: "Failed"
                    )
                )
            ),
            canStartCapture: { true },
            blockedStatus: { _ in nil },
            updateStatus: { statuses.append($0) },
            startCapture: { attempt in
                startAttempts.append(attempt)
                return startAttempts.count == 2
            }
        )

        await waitUntil {
            let recordedRetryDurations = await sleeper.recordedDurations()
            return statuses == ["Restarting..."]
                && startAttempts.map(\.successMessage) == ["first"]
                && recordedRetryDurations == [.seconds(3)]
                && controller.hasPendingStart
        }

        XCTAssertEqual(statuses, ["Restarting..."])
        XCTAssertEqual(startAttempts.map(\.successMessage), ["first"])
        let recordedRetryDurations = await sleeper.recordedDurations()
        XCTAssertEqual(recordedRetryDurations, [.seconds(3)])
        XCTAssertTrue(controller.hasPendingStart)

        await sleeper.resumeAll()
        await waitUntil {
            startAttempts.map(\.successMessage) == ["first", "second"]
                && !controller.hasPendingStart
        }

        XCTAssertEqual(startAttempts.map(\.successMessage), ["first", "second"])
        XCTAssertFalse(controller.hasPendingStart)
    }

    func testCancelPendingStartPreventsDelayedAttempt() async {
        let sleeper = CaptureStartControllerSleepProbe()
        let controller = CaptureStartController(
            sleep: { duration in
                await sleeper.sleep(for: duration)
            }
        )
        var startAttempts = 0

        controller.scheduleStart(
            request: CaptureStartRequest(
                status: "Resuming...",
                initialDelay: .seconds(2),
                attempt: CaptureStartAttempt(
                    successMessage: "started",
                    failurePrefix: "failed",
                    failureStatus: "Error"
                )
            ),
            canStartCapture: { true },
            blockedStatus: { _ in nil },
            updateStatus: { _ in },
            startCapture: { _ in
                startAttempts += 1
                return true
            }
        )

        await settleScheduledTasks()
        let recordedInitialDurations = await sleeper.recordedDurations()
        XCTAssertEqual(recordedInitialDurations, [.seconds(2)])
        XCTAssertTrue(controller.hasPendingStart)

        controller.cancelPendingStart()
        await sleeper.resumeAll()
        await settleScheduledTasks()

        XCTAssertEqual(startAttempts, 0)
        XCTAssertFalse(controller.hasPendingStart)
    }

    private func settleScheduledTasks() async {
        await Task.yield()
        await Task.yield()
        await Task.yield()
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout

        while clock.now < deadline {
            if await condition() {
                return
            }
            await settleScheduledTasks()
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

private actor CaptureStartControllerSleepProbe {
    private var durations: [Duration] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func sleep(for duration: Duration) async {
        durations.append(duration)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func recordedDurations() -> [Duration] {
        durations
    }

    func resumeAll() {
        let pendingContinuations = continuations
        continuations.removeAll()
        for continuation in pendingContinuations {
            continuation.resume()
        }
    }
}
