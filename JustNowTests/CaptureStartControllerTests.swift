import XCTest
@testable import JustNow

@MainActor
final class CaptureStartControllerTests: XCTestCase {
    func testManualResumeInsideOverlayStartsExactlyOnceAfterDismissal() async {
        let startController = CaptureStartController(sleep: { _ in
            XCTFail("The overlay must block manual resume before its delay is scheduled")
        })
        var isCapturing = true
        var isOverlayVisible = false
        var startCount = 0
        var stopCount = 0
        var startRequestCount = 0
        var statuses: [String] = []
        var eventController: CaptureEventController!
        eventController = CaptureEventController(
            context: {
                CaptureEventContext(
                    hasCaptureManager: true,
                    isCapturing: isCapturing,
                    isSetupCaptureInProgress: false,
                    hasPendingStart: startController.hasPendingStart,
                    isOverlayVisible: isOverlayVisible
                )
            },
            scheduleStart: { request in
                startRequestCount += 1
                startController.scheduleStart(
                    request: request,
                    canStartCapture: { eventController.canStartCapture() },
                    blockedStatus: { eventController.blockedStatus(includeOverlay: $0) },
                    updateStatus: { statuses.append($0) },
                    startCapture: { _ in
                        XCTAssertFalse(isOverlayVisible)
                        startCount += 1
                        isCapturing = true
                        return .started
                    }
                )
            },
            cancelPendingStart: { startController.cancelPendingStart() },
            scheduleStop: { _ in
                // Model a completed stop, not a stop still racing overlay open.
                stopCount += 1
                isCapturing = false
            },
            updateStatus: { statuses.append($0) },
            enableBlackFrameFilter: { _ in },
            endForegroundActivity: {},
            updatePauseMenu: { _ in },
            logger: { _ in }
        )
        defer {
            startController.cancelPendingStart()
            eventController = nil
        }

        eventController.toggleCapturePause()
        XCTAssertTrue(eventController.isUserPaused)
        XCTAssertFalse(isCapturing)
        XCTAssertEqual(stopCount, 1)
        XCTAssertFalse(startController.hasPendingStart)

        isOverlayVisible = true
        eventController.handleOverlayVisibilityChanged(isVisible: true)
        eventController.toggleCapturePause()
        XCTAssertFalse(eventController.isUserPaused)
        XCTAssertEqual(startRequestCount, 1)

        // Wait for the real start controller to discard the blocked request
        // before dismissal, so it cannot accidentally start after visibility changes.
        await waitUntil {
            statuses.last == "Paused (Overlay)" && !startController.hasPendingStart
        }
        XCTAssertEqual(startCount, 0)
        XCTAssertFalse(isCapturing)

        isOverlayVisible = false
        eventController.handleOverlayVisibilityChanged(isVisible: false)
        await waitUntil { !startController.hasPendingStart }

        XCTAssertEqual(startRequestCount, 2, "Dismissal must preserve manual resume intent")
        XCTAssertEqual(startCount, 1)
        XCTAssertTrue(isCapturing)
    }

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

    func testScheduleStartAppliesBlockedStatusWhenBlockedAfterDelay() async {
        let sleeper = CaptureStartControllerSleepProbe()
        let controller = CaptureStartController(
            sleep: { duration in
                await sleeper.sleep(for: duration)
            }
        )
        var statuses: [String] = []
        var canStart = true
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
            canStartCapture: { canStart },
            blockedStatus: { _ in "Screen Locked" },
            updateStatus: { statuses.append($0) },
            startCapture: { _ in
                startAttempts += 1
                return .started
            }
        )

        await waitUntil {
            statuses == ["Resuming..."] && controller.hasPendingStart
        }

        canStart = false
        await sleeper.resumeAll()
        await waitUntil { !controller.hasPendingStart }

        XCTAssertEqual(statuses, ["Resuming...", "Screen Locked"])
        XCTAssertEqual(startAttempts, 0)
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
                    failureStatus: "Recovering…"
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
                        failureStatus: "Recovering…"
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
                    failureStatus: "Recovering…"
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
                    failureStatus: "Recovering…"
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

    func testStopCompletionClearsDeferredOwnershipRestoredAfterCancellation() {
        let controller = CaptureStartController()

        controller.cancelPendingStart()
        let stopGeneration = controller.generationSnapshot()
        // Models a late broker cooldown callback before the queued coordinator
        // stop begins executing.
        controller.beginDeferredStart()
        XCTAssertTrue(controller.hasPendingStart)

        controller.completeDeferredStartIfNoNewerRequest(since: stopGeneration)
        XCTAssertFalse(controller.hasPendingStart)
    }

    func testStopCompletionDoesNotCancelNewerStartRequest() async {
        let sleeper = CaptureStartControllerSleepProbe()
        let controller = CaptureStartController(
            sleep: { duration in
                await sleeper.sleep(for: duration)
            }
        )
        var startAttempts = 0

        controller.cancelPendingStart()
        let stopGeneration = controller.generationSnapshot()
        controller.beginDeferredStart()

        controller.scheduleStart(
            request: CaptureStartRequest(
                status: "Resuming...",
                initialDelay: .seconds(1),
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

        await waitUntil {
            await sleeper.recordedDurations() == [.seconds(1)]
                && controller.hasPendingStart
        }

        controller.completeDeferredStartIfNoNewerRequest(since: stopGeneration)
        XCTAssertTrue(controller.hasPendingStart)

        await sleeper.resumeAll()
        await waitUntil { startAttempts == 1 && !controller.hasPendingStart }

        XCTAssertEqual(startAttempts, 1)
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
