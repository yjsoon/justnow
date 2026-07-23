import XCTest
@testable import JustNow

final class ScreenshotCaptureExecutionTests: XCTestCase {
    func testRunKeepsSynchronousFrameworkWorkOffMainThread() async throws {
        let ranOnMainThread = try await ScreenshotCaptureExecution.run {
            Thread.isMainThread
        }

        XCTAssertFalse(ranOnMainThread)
    }

    func testCancellationReturnsWhileUnderlyingWorkRetainsSerialPermit() async throws {
        let latch = ScreenshotCaptureExecutionTestLatch()
        let state = ScreenshotCaptureExecutionTestState()

        let first = Task {
            do {
                _ = try await ScreenshotCaptureExecution.run {
                    await latch.wait()
                    return true
                }
                XCTFail("Cancelled capture should not return a value")
            } catch is CancellationError {
                await state.noteCancellationReturned()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        await waitUntil { await latch.waiterCount == 1 }

        first.cancel()
        await waitUntil { await state.cancellationReturned }

        let second = Task {
            try await ScreenshotCaptureExecution.run(
                workerDidStart: {
                    Task {
                        await state.noteSecondWorkerStarted()
                    }
                }
            ) {
                await state.noteSecondOperationStarted()
            }
        }
        await waitUntil { await state.secondWorkerStarted }
        let startedWhileFirstRequestWasBlocked = await state.secondOperationStarted
        XCTAssertFalse(startedWhileFirstRequestWasBlocked)

        await latch.resume()
        try await second.value
        let startedAfterFirstRequestCompleted = await state.secondOperationStarted
        XCTAssertTrue(startedAfterFirstRequestCompleted)
    }

    func testCancellingQueuedRequestPreventsItsOperationFromStarting() async throws {
        let latch = ScreenshotCaptureExecutionTestLatch()
        let state = ScreenshotCaptureExecutionTestState()

        let holder = Task {
            try await ScreenshotCaptureExecution.run {
                await latch.wait()
            }
        }
        await waitUntil { await latch.waiterCount == 1 }

        let queued = Task {
            do {
                try await ScreenshotCaptureExecution.run(
                    workerDidStart: {
                        Task {
                            await state.noteQueuedWorkerStarted()
                        }
                    }
                ) {
                    await state.noteQueuedOperationStarted()
                }
                XCTFail("Cancelled queued capture should not return a value")
            } catch is CancellationError {
                await state.noteQueuedCancellationReturned()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        await waitUntil { await state.queuedWorkerStarted }

        queued.cancel()
        await waitUntil { await state.queuedCancellationReturned }

        await latch.resume()
        try await holder.value
        try await ScreenshotCaptureExecution.run {}
        await queued.value

        let queuedOperationStarted = await state.queuedOperationStarted
        XCTAssertFalse(queuedOperationStarted)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @Sendable () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

private actor ScreenshotCaptureExecutionTestLatch {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var waiterCount: Int { continuations.count }

    func wait() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resume() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

private actor ScreenshotCaptureExecutionTestState {
    private(set) var cancellationReturned = false
    private(set) var secondWorkerStarted = false
    private(set) var secondOperationStarted = false
    private(set) var queuedWorkerStarted = false
    private(set) var queuedOperationStarted = false
    private(set) var queuedCancellationReturned = false

    func noteCancellationReturned() {
        cancellationReturned = true
    }

    func noteSecondWorkerStarted() {
        secondWorkerStarted = true
    }

    func noteSecondOperationStarted() {
        secondOperationStarted = true
    }

    func noteQueuedWorkerStarted() {
        queuedWorkerStarted = true
    }

    func noteQueuedOperationStarted() {
        queuedOperationStarted = true
    }

    func noteQueuedCancellationReturned() {
        queuedCancellationReturned = true
    }
}
