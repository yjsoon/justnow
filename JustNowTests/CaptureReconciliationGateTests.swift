import XCTest
@testable import JustNow

@MainActor
final class CaptureReconciliationGateTests: XCTestCase {
    func testSerialisesOperationsInFIFOOrder() async throws {
        let gate = CaptureReconciliationGate()
        let latch = ReconciliationGateTestLatch()
        var events: [String] = []

        let first = Task { @MainActor in
            try await gate.withPermit {
                events.append("first-enter")
                await latch.wait()
                events.append("first-exit")
            }
        }
        await waitUntil { events == ["first-enter"] }

        let second = Task { @MainActor in
            try await gate.withPermit {
                events.append("second-enter")
            }
        }
        await waitUntil { gate.queuedWaiterCountForTesting == 1 }
        XCTAssertEqual(events, ["first-enter"])

        await latch.resume()
        try await first.value
        try await second.value
        XCTAssertEqual(events, ["first-enter", "first-exit", "second-enter"])
    }

    func testCancellingQueuedOperationDoesNotLeakPermit() async throws {
        let gate = CaptureReconciliationGate()
        let latch = ReconciliationGateTestLatch()
        var secondEntered = false

        let first = Task { @MainActor in
            try await gate.withPermit { await latch.wait() }
        }
        await waitUntil { await latch.waiterCount == 1 }

        let second = Task { @MainActor in
            try await gate.withPermit { secondEntered = true }
        }
        await waitUntil { gate.queuedWaiterCountForTesting == 1 }
        second.cancel()
        do {
            try await second.value
            XCTFail("Cancelled waiter should not acquire the permit")
        } catch is CancellationError {
            // Expected.
        }

        await latch.resume()
        try await first.value
        try await gate.withPermit {}
        XCTAssertFalse(secondEntered)
    }

    func testCancellingActiveOperationDoesNotReleaseUntilItUnwinds() async {
        let gate = CaptureReconciliationGate()
        let latch = ReconciliationGateTestLatch()
        var secondEntered = false

        let first = Task { @MainActor in
            try await gate.withPermit {
                await latch.wait()
            }
        }
        await waitUntil { await latch.waiterCount == 1 }

        let second = Task { @MainActor in
            try await gate.withPermit { secondEntered = true }
        }
        await waitUntil { gate.queuedWaiterCountForTesting == 1 }
        first.cancel()
        await Task.yield()
        XCTAssertFalse(secondEntered)

        await latch.resume()
        _ = try? await first.value
        _ = try? await second.value
        XCTAssertTrue(secondEntered)
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
            if await condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

private actor ReconciliationGateTestLatch {
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
