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
                return .started
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
                return startAttempts.count == 2 ? .started : .failed
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
                return .started
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

    func testDeferredStartDoesNotConsumeRetryPolicy() async {
        let sleeper = CaptureStartControllerSleepProbe()
        let controller = CaptureStartController(
            sleep: { duration in
                await sleeper.sleep(for: duration)
            }
        )
        var startAttempts: [String] = []

        controller.scheduleStart(
            request: CaptureStartRequest(
                status: "Restarting...",
                attempt: CaptureStartAttempt(
                    successMessage: "first",
                    failurePrefix: "first deferred",
                    failureStatus: "Recovering"
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
            updateStatus: { _ in },
            startCapture: { attempt in
                startAttempts.append(attempt.successMessage)
                return .deferred
            }
        )

        await waitUntil { startAttempts == ["first"] }

        XCTAssertEqual(startAttempts, ["first"])
        let recordedDurations = await sleeper.recordedDurations()
        XCTAssertTrue(recordedDurations.isEmpty)
        XCTAssertTrue(controller.hasPendingStart)

        controller.cancelPendingStart()
        XCTAssertFalse(controller.hasPendingStart)
    }

    func testDeferredRetryRemainsVisibleToLifecycle() async {
        let sleeper = CaptureStartControllerSleepProbe()
        let controller = CaptureStartController(
            sleep: { duration in
                await sleeper.sleep(for: duration)
            }
        )
        var attemptCount = 0

        controller.scheduleStart(
            request: CaptureStartRequest(
                status: "Restarting...",
                attempt: CaptureStartAttempt(
                    successMessage: "first",
                    failurePrefix: "first failed",
                    failureStatus: "Error"
                ),
                retry: CaptureStartRetryPolicy(
                    delay: .seconds(3),
                    attempt: CaptureStartAttempt(
                        successMessage: "second",
                        failurePrefix: "second deferred",
                        failureStatus: "Recovering"
                    )
                )
            ),
            canStartCapture: { true },
            blockedStatus: { _ in nil },
            updateStatus: { _ in },
            startCapture: { _ in
                attemptCount += 1
                return attemptCount == 1 ? .failed : .deferred
            }
        )

        await waitUntil { await sleeper.recordedDurations() == [.seconds(3)] }
        await sleeper.resumeAll()
        await waitUntil { attemptCount == 2 && controller.hasPendingStart }

        XCTAssertTrue(controller.hasPendingStart)
        controller.cancelPendingStart()
    }

    func testCancellationCannotRestoreDeferredState() async {
        let attemptGate = CaptureStartControllerAttemptGate()
        let controller = CaptureStartController()

        controller.scheduleStart(
            request: CaptureStartRequest(
                status: "Restarting...",
                attempt: CaptureStartAttempt(
                    successMessage: "first",
                    failurePrefix: "first deferred",
                    failureStatus: "Recovering"
                )
            ),
            canStartCapture: { true },
            blockedStatus: { _ in nil },
            updateStatus: { _ in },
            startCapture: { _ in await attemptGate.waitThenDefer() }
        )

        await waitUntil { await attemptGate.isWaiting }
        controller.cancelPendingStart()
        await attemptGate.resume()
        await settleScheduledTasks()

        XCTAssertFalse(controller.hasPendingStart)
    }

    func testRecoveryCompletionBeforeDeferredResultDoesNotLeaveStaleState() async {
        let controller = CaptureStartController()

        controller.scheduleStart(
            request: CaptureStartRequest(
                status: "Restarting...",
                attempt: CaptureStartAttempt(
                    successMessage: "first",
                    failurePrefix: "first deferred",
                    failureStatus: "Recovering"
                )
            ),
            canStartCapture: { true },
            blockedStatus: { _ in nil },
            updateStatus: { _ in },
            startCapture: { _ in
                controller.completeDeferredStart()
                return .deferred
            }
        )

        await settleScheduledTasks()

        XCTAssertFalse(controller.hasPendingStart)
    }

    func testLaterCooldownReestablishesDeferredLifecycleOwnership() {
        let controller = CaptureStartController()

        controller.beginDeferredStart()
        XCTAssertTrue(controller.hasPendingStart)

        controller.completeDeferredStart()
        XCTAssertFalse(controller.hasPendingStart)

        controller.beginDeferredStart()
        XCTAssertTrue(controller.hasPendingStart)
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

private actor CaptureStartControllerAttemptGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func waitThenDefer() async -> CaptureStartResult {
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return .deferred
    }

    func resume() {
        continuation?.resume()
        continuation = nil
        isWaiting = false
    }
}
