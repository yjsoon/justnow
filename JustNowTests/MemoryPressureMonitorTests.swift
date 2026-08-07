import XCTest
@testable import JustNow

@MainActor
final class MemoryPressureMonitorTests: XCTestCase {
    func testMonitorSerialisesEventsAndCriticalWinsPendingCoalescing() async {
        let source = MemoryPressureEventSourceProbe()
        let firstStarted = expectation(description: "first warning started")
        let criticalFinished = expectation(description: "critical finished")
        let gate = MemoryPressureTestGate()
        var received: [FrameMemoryPressureLevel] = []
        var activeHandlers = 0
        var maximumActiveHandlers = 0
        let monitor = MemoryPressureMonitor(eventSource: source) { level in
            activeHandlers += 1
            maximumActiveHandlers = max(maximumActiveHandlers, activeHandlers)
            received.append(level)
            if received.count == 1 {
                firstStarted.fulfill()
                await gate.wait()
            }
            activeHandlers -= 1
            if level == .critical {
                criticalFinished.fulfill()
            }
        }
        monitor.start()

        source.emit(.warning)
        await fulfillment(of: [firstStarted], timeout: 1)
        source.emit(.warning)
        source.emit(.critical)
        source.emit(.warning)
        await gate.open()
        await fulfillment(of: [criticalFinished], timeout: 1)

        XCTAssertEqual(received, [.warning, .critical])
        XCTAssertEqual(maximumActiveHandlers, 1)
        await monitor.cancel()
    }

    func testMonitorDeliversRepeatedCompletedWarningsAndCancelStopsCallbacks() async {
        let source = MemoryPressureEventSourceProbe()
        let firstDelivered = expectation(description: "first warning delivered")
        let secondDelivered = expectation(description: "second warning delivered")
        let afterCancel = expectation(description: "no callback after cancel")
        afterCancel.isInverted = true
        var count = 0
        let monitor = MemoryPressureMonitor(eventSource: source) { _ in
            count += 1
            if count == 1 {
                firstDelivered.fulfill()
            } else if count == 2 {
                secondDelivered.fulfill()
            } else {
                afterCancel.fulfill()
            }
        }
        monitor.start()

        source.emit(.warning)
        await fulfillment(of: [firstDelivered], timeout: 1)
        source.emit(.warning)
        await fulfillment(of: [secondDelivered], timeout: 1)
        await monitor.cancel()
        source.emit(.critical)
        await fulfillment(of: [afterCancel], timeout: 0.1)

        XCTAssertEqual(count, 2)
        XCTAssertTrue(source.didCancel)
    }

    func testCancelWaitsForSuspendedHandlerAndFencesQueuedCallbacks() async {
        final class CompletionState {
            var mayFinish = false
        }

        let source = MemoryPressureEventSourceProbe()
        let handlerStarted = expectation(description: "handler started")
        let cancellationReturnedEarly = expectation(description: "cancel must await handler")
        cancellationReturnedEarly.isInverted = true
        let cancellationFinished = expectation(description: "cancel finished")
        let gate = MemoryPressureTestGate()
        let completionState = CompletionState()
        var received: [FrameMemoryPressureLevel] = []
        let monitor = MemoryPressureMonitor(eventSource: source) { level in
            received.append(level)
            handlerStarted.fulfill()
            await gate.wait()
        }
        monitor.start()

        source.emit(.warning)
        await fulfillment(of: [handlerStarted], timeout: 1)
        source.emit(.critical)

        let cancellationTask = Task { @MainActor in
            await monitor.cancel()
            if !completionState.mayFinish {
                cancellationReturnedEarly.fulfill()
            }
            cancellationFinished.fulfill()
        }
        await fulfillment(of: [cancellationReturnedEarly], timeout: 0.05)
        XCTAssertTrue(source.didCancel)

        source.emit(.warning)
        completionState.mayFinish = true
        await gate.open()
        await fulfillment(of: [cancellationFinished], timeout: 1)
        await cancellationTask.value

        XCTAssertEqual(received, [.warning])
    }
}

private final class MemoryPressureEventSourceProbe: MemoryPressureEventSource, @unchecked Sendable {
    private var handler: (@Sendable (FrameMemoryPressureLevel) -> Void)?
    private(set) var didCancel = false

    func setEventHandler(_ handler: @escaping @Sendable (FrameMemoryPressureLevel) -> Void) {
        self.handler = handler
    }

    func start() {}

    func cancel() {
        didCancel = true
    }

    func emit(_ level: FrameMemoryPressureLevel) {
        handler?(level)
    }
}

private actor MemoryPressureTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
