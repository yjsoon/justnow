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
        monitor.cancel()
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
        monitor.cancel()
        source.emit(.critical)
        await fulfillment(of: [afterCancel], timeout: 0.1)

        XCTAssertEqual(count, 2)
        XCTAssertTrue(source.didCancel)
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
