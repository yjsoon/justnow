import Foundation
import XCTest
@testable import JustNow

@MainActor
final class CaptureRequestBrokerTests: XCTestCase {
    func testSerialisesInteractiveRequestsAcrossOwners() async throws {
        let clock = BrokerTestClock()
        let broker = makeBroker(clock: clock)
        let firstOwner = UUID()
        let secondOwner = UUID()
        let gate = BrokerTestGate()
        var started: [String] = []
        var activeRequests = 0
        var maximumActiveRequests = 0

        let first = Task { @MainActor () throws -> String in
            try await broker.perform(owner: firstOwner, kind: .interactive) {
                started.append("first")
                activeRequests += 1
                maximumActiveRequests = max(maximumActiveRequests, activeRequests)
                await gate.wait()
                activeRequests -= 1
                return "first"
            }
        }
        await waitUntil { gate.waiterCount == 1 }

        let second = Task { @MainActor () throws -> String in
            try await broker.perform(owner: secondOwner, kind: .interactive) {
                started.append("second")
                activeRequests += 1
                maximumActiveRequests = max(maximumActiveRequests, activeRequests)
                activeRequests -= 1
                return "second"
            }
        }
        await settleTasks()

        XCTAssertEqual(started, ["first"])
        XCTAssertEqual(maximumActiveRequests, 1)

        gate.resumeNext()
        let firstValue = try await first.value
        let secondValue = try await second.value
        XCTAssertEqual(firstValue, "first")
        XCTAssertEqual(secondValue, "second")
        XCTAssertEqual(started, ["first", "second"])
        XCTAssertEqual(maximumActiveRequests, 1)
    }

    func testFalseDenialOpensCircuitBeforeQueuedOwnerCanReachOS() async {
        let clock = BrokerTestClock()
        let broker = makeBroker(clock: clock)
        let gate = BrokerTestGate()
        var secondOSCalls = 0

        let first = Task { @MainActor () -> Error? in
            do {
                try await broker.perform(owner: UUID(), kind: .interactive) {
                    await gate.wait()
                    throw self.falsePermissionDenial()
                }
                return nil
            } catch {
                return error
            }
        }
        await waitUntil { gate.waiterCount == 1 }

        let second = Task { @MainActor () -> Error? in
            do {
                try await broker.perform(owner: UUID(), kind: .interactive) {
                    secondOSCalls += 1
                }
                return nil
            } catch {
                return error
            }
        }
        await settleTasks()

        gate.resumeNext()
        let firstError = await first.value
        let secondError = await second.value

        XCTAssertEqual((firstError as NSError?)?.code, -3801)
        XCTAssertEqual(secondOSCalls, 0)
        XCTAssertEqual(
            secondError as? CaptureRequestBrokerError,
            .cooldown(until: clock.date.addingTimeInterval(CaptureFailureRecovery.falsePermissionDenialDelay))
        )
    }

    func testCooldownFailsFastWithoutCallingOSRequest() async {
        let clock = BrokerTestClock()
        let broker = makeBroker(clock: clock)
        var calls = 0

        _ = await captureError(from: broker, owner: UUID()) {
            throw self.falsePermissionDenial()
        }

        let error = await captureError(from: broker, owner: UUID()) {
            calls += 1
        }

        XCTAssertEqual(calls, 0)
        XCTAssertEqual(
            error as? CaptureRequestBrokerError,
            .cooldown(until: clock.date.addingTimeInterval(CaptureFailureRecovery.falsePermissionDenialDelay))
        )
    }

    func testOnlyOneHalfOpenProbeRunsAndSuccessClosesCircuit() async throws {
        let clock = BrokerTestClock()
        var logs: [String] = []
        let broker = makeBroker(clock: clock, log: { logs.append($0) })
        let probeGate = BrokerTestGate()
        var started: [String] = []

        _ = await captureError(from: broker, owner: UUID()) {
            throw self.falsePermissionDenial()
        }
        clock.date = clock.date.addingTimeInterval(CaptureFailureRecovery.falsePermissionDenialDelay)

        let probe = Task { @MainActor () throws -> String in
            try await broker.perform(owner: UUID(), kind: .interactive) {
                started.append("probe")
                await probeGate.wait()
                return "probe"
            }
        }
        await waitUntil { probeGate.waiterCount == 1 }

        let queued = Task { @MainActor () throws -> String in
            try await broker.perform(owner: UUID(), kind: .interactive) {
                started.append("queued")
                return "queued"
            }
        }
        await settleTasks()
        XCTAssertEqual(started, ["probe"])

        probeGate.resumeNext()
        let probeValue = try await probe.value
        let queuedValue = try await queued.value
        XCTAssertEqual(probeValue, "probe")
        XCTAssertEqual(queuedValue, "queued")
        XCTAssertEqual(started, ["probe", "queued"])
        XCTAssertEqual(logs.filter { $0.contains("circuit opened") }.count, 1)
        XCTAssertEqual(logs.filter { $0.contains("circuit recovered") }.count, 1)
    }

    func testFalseDenialFromHalfOpenProbeReopensCircuit() async {
        let clock = BrokerTestClock()
        var logs: [String] = []
        let broker = makeBroker(clock: clock, log: { logs.append($0) })

        _ = await captureError(from: broker, owner: UUID()) {
            throw self.falsePermissionDenial()
        }
        clock.date = clock.date.addingTimeInterval(CaptureFailureRecovery.falsePermissionDenialDelay)

        let probeError = await captureError(from: broker, owner: UUID()) {
            throw self.falsePermissionDenial()
        }
        XCTAssertEqual((probeError as NSError?)?.code, -3801)

        let blockedError = await captureError(from: broker, owner: UUID()) {
            XCTFail("A reopened circuit must not call the OS request")
        }
        XCTAssertEqual(
            blockedError as? CaptureRequestBrokerError,
            .cooldown(until: clock.date.addingTimeInterval(CaptureFailureRecovery.falsePermissionDenialDelay))
        )
        XCTAssertEqual(logs.filter { $0.contains("circuit opened") }.count, 1)
        XCTAssertEqual(logs.filter { $0.contains("circuit reopened") }.count, 1)
    }

    func testCancelledHalfOpenProbeKeepsSharedCircuitOpen() async {
        let clock = BrokerTestClock()
        let broker = makeBroker(clock: clock)
        let gate = BrokerTestGate()

        _ = await captureError(from: broker, owner: UUID()) {
            throw self.falsePermissionDenial()
        }
        clock.date = clock.date.addingTimeInterval(CaptureFailureRecovery.falsePermissionDenialDelay)

        let probe = Task { @MainActor () -> Error? in
            await self.captureError(from: broker, owner: UUID()) {
                await gate.wait()
                try Task.checkCancellation()
            }
        }
        await waitUntil { gate.waiterCount == 1 }

        probe.cancel()
        gate.resumeNext()
        let probeError = await probe.value
        XCTAssertTrue(probeError is CancellationError)

        let otherOwnerError = await captureError(from: broker, owner: UUID()) {
            XCTFail("A cancelled probe must not clear the shared circuit")
        }
        XCTAssertEqual(
            otherOwnerError as? CaptureRequestBrokerError,
            .cooldown(until: clock.date.addingTimeInterval(CaptureFailureRecovery.falsePermissionDenialDelay))
        )
    }

    func testCancellingOneOwnerLeavesOtherQueuedOwnerIntact() async throws {
        let clock = BrokerTestClock()
        let broker = makeBroker(clock: clock)
        let firstOwner = UUID()
        let cancelledOwner = UUID()
        let survivingOwner = UUID()
        let gate = BrokerTestGate()
        var started: [String] = []

        let first = Task { @MainActor () throws -> String in
            try await broker.perform(owner: firstOwner, kind: .interactive) {
                started.append("first")
                await gate.wait()
                return "first"
            }
        }
        await waitUntil { gate.waiterCount == 1 }

        let cancelled = Task { @MainActor () -> Error? in
            await captureError(from: broker, owner: cancelledOwner) {
                started.append("cancelled")
            }
        }
        let surviving = Task { @MainActor () throws -> String in
            try await broker.perform(owner: survivingOwner, kind: .interactive) {
                started.append("surviving")
                return "surviving"
            }
        }
        await settleTasks()

        broker.cancelRequests(for: cancelledOwner)
        let cancelledError = await cancelled.value
        XCTAssertTrue(cancelledError is CancellationError)

        gate.resumeNext()
        let firstValue = try await first.value
        let survivingValue = try await surviving.value
        XCTAssertEqual(firstValue, "first")
        XCTAssertEqual(survivingValue, "surviving")
        XCTAssertEqual(started, ["first", "surviving"])
    }

    func testCancellingAnOwnerDoesNotResetSharedCooldown() async {
        let clock = BrokerTestClock()
        let broker = makeBroker(clock: clock)
        let stoppedOwner = UUID()

        _ = await captureError(from: broker, owner: stoppedOwner) {
            throw self.falsePermissionDenial()
        }
        broker.cancelRequests(for: stoppedOwner)

        let otherOwnerError = await captureError(from: broker, owner: UUID()) {
            XCTFail("A stopped owner must not clear the shared circuit")
        }
        XCTAssertEqual(
            otherOwnerError as? CaptureRequestBrokerError,
            .cooldown(until: clock.date.addingTimeInterval(CaptureFailureRecovery.falsePermissionDenialDelay))
        )
    }

    func testNonMismatchErrorDoesNotOpenCircuitOrBlockNextRequest() async throws {
        let clock = BrokerTestClock()
        let broker = makeBroker(clock: clock)
        var calls = 0

        let firstError = await captureError(from: broker, owner: UUID()) {
            throw NSError(
                domain: "com.apple.ScreenCaptureKit.CoreGraphicsErrorDomain",
                code: 1004
            )
        }
        XCTAssertEqual((firstError as NSError?)?.code, 1004)

        try await broker.perform(owner: UUID(), kind: .interactive) {
            calls += 1
        }
        XCTAssertEqual(calls, 1)
    }

    func testRealPermissionDenialDoesNotOpenBrokerCircuit() async throws {
        let clock = BrokerTestClock()
        let broker = makeBroker(clock: clock, hasScreenRecordingPermission: false)
        var nextRequestCalls = 0

        let denialError = await captureError(from: broker, owner: UUID()) {
            throw self.falsePermissionDenial()
        }
        XCTAssertEqual((denialError as NSError?)?.code, -3801)

        try await broker.perform(owner: UUID(), kind: .interactive) {
            nextRequestCalls += 1
        }
        XCTAssertEqual(nextRequestCalls, 1)
    }

    func testPeriodicRequestIsDroppedRatherThanQueuedBehindActiveRequest() async throws {
        let clock = BrokerTestClock()
        let broker = makeBroker(clock: clock)
        let gate = BrokerTestGate()
        var periodicCalls = 0

        let active = Task { @MainActor () throws -> Void in
            try await broker.perform(owner: UUID(), kind: .interactive) {
                await gate.wait()
            }
        }
        await waitUntil { gate.waiterCount == 1 }

        let error = await captureError(from: broker, owner: UUID(), kind: .periodic) {
            periodicCalls += 1
        }
        XCTAssertEqual(error as? CaptureRequestBrokerError, .droppedPeriodicRequest)
        XCTAssertEqual(periodicCalls, 0)

        gate.resumeNext()
        try await active.value
    }

    func testPeriodicOwnerThatLosesAlignedTickGetsNextFreshTurn() async throws {
        let clock = BrokerTestClock()
        let broker = makeBroker(clock: clock)
        let gate = BrokerTestGate()
        let firstOwner = UUID()
        let losingOwner = UUID()
        var calls: [String] = []

        let first = Task { @MainActor () throws -> Void in
            try await broker.perform(owner: firstOwner, kind: .periodic) {
                calls.append("first")
                await gate.wait()
            }
        }
        await waitUntil { gate.waiterCount == 1 }

        let losingTick = await captureError(
            from: broker,
            owner: losingOwner,
            kind: .periodic
        ) {
            calls.append("losing-stale")
        }
        XCTAssertEqual(losingTick as? CaptureRequestBrokerError, .droppedPeriodicRequest)
        XCTAssertEqual(calls, ["first"])

        gate.resumeNext()
        try await first.value

        let winnerNextTick = await captureError(
            from: broker,
            owner: firstOwner,
            kind: .periodic
        ) {
            calls.append("first-again")
        }
        XCTAssertEqual(winnerNextTick as? CaptureRequestBrokerError, .droppedPeriodicRequest)

        try await broker.perform(owner: losingOwner, kind: .periodic) {
            calls.append("losing-fresh")
        }
        XCTAssertEqual(calls, ["first", "losing-fresh"])
    }

    private func makeBroker(
        clock: BrokerTestClock,
        hasScreenRecordingPermission: Bool = true,
        log: @escaping @MainActor (String) -> Void = { _ in }
    ) -> CaptureRequestBroker {
        CaptureRequestBroker(
            now: { clock.date },
            hasScreenRecordingPermission: { hasScreenRecordingPermission },
            log: log
        )
    }

    private func captureError(
        from broker: CaptureRequestBroker,
        owner: UUID,
        kind: CaptureRequestKind = .interactive,
        operation: @escaping @MainActor () async throws -> Void
    ) async -> Error? {
        do {
            try await broker.perform(owner: owner, kind: kind, operation: operation)
            return nil
        } catch {
            return error
        }
    }

    private func falsePermissionDenial() -> NSError {
        NSError(
            domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
            code: -3801
        )
    }

    private func settleTasks() async {
        await Task.yield()
        await Task.yield()
        await Task.yield()
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let continuousClock = ContinuousClock()
        let deadline = continuousClock.now + timeout

        while continuousClock.now < deadline {
            if condition() { return }
            await settleTasks()
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

@MainActor
private final class BrokerTestClock {
    var date = Date(timeIntervalSinceReferenceDate: 1_000)
}

@MainActor
private final class BrokerTestGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var waiterCount: Int { continuations.count }

    func wait() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}
