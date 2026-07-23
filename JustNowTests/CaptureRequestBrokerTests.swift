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
            try await broker.perform(owner: firstOwner) {
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
            try await broker.perform(owner: secondOwner) {
                started.append("second")
                activeRequests += 1
                maximumActiveRequests = max(maximumActiveRequests, activeRequests)
                activeRequests -= 1
                return "second"
            }
        }
        await waitUntil { broker.queuedRequestCountForTesting == 1 }

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
                try await broker.perform(owner: UUID()) {
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
                try await broker.perform(owner: UUID()) {
                    secondOSCalls += 1
                }
                return nil
            } catch {
                return error
            }
        }
        await waitUntil { broker.queuedRequestCountForTesting == 1 }

        gate.resumeNext()
        let firstError = await first.value
        let secondError = await second.value

        XCTAssertEqual((firstError as NSError?)?.code, -3801)
        XCTAssertEqual(secondOSCalls, 0)
        XCTAssertEqual(
            secondError as? CaptureRequestBrokerError,
            .cooldown(
                untilMonotonicTime: clock.monotonicTime
                    + CaptureFailureRecovery.falsePermissionDenialDelay
            )
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
            .cooldown(
                untilMonotonicTime: clock.monotonicTime
                    + CaptureFailureRecovery.falsePermissionDenialDelay
            )
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
        clock.advance(by: CaptureFailureRecovery.falsePermissionDenialDelay)

        let probe = Task { @MainActor () throws -> String in
            try await broker.perform(owner: UUID()) {
                started.append("probe")
                await probeGate.wait()
                return "probe"
            }
        }
        await waitUntil { probeGate.waiterCount == 1 }

        let queued = Task { @MainActor () throws -> String in
            try await broker.perform(owner: UUID()) {
                started.append("queued")
                return "queued"
            }
        }
        await waitUntil { broker.queuedRequestCountForTesting == 1 }
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
        clock.advance(by: CaptureFailureRecovery.falsePermissionDenialDelay)

        let probeError = await captureError(from: broker, owner: UUID()) {
            throw self.falsePermissionDenial()
        }
        XCTAssertEqual((probeError as NSError?)?.code, -3801)

        let blockedError = await captureError(from: broker, owner: UUID()) {
            XCTFail("A reopened circuit must not call the OS request")
        }
        // A failed probe is fresh evidence the desync episode is ongoing, so
        // the reopened circuit escalates to double the base cooldown.
        XCTAssertEqual(
            blockedError as? CaptureRequestBrokerError,
            .cooldown(
                untilMonotonicTime: clock.monotonicTime
                    + CaptureFailureRecovery.falsePermissionDenialDelay * 2
            )
        )
        XCTAssertEqual(logs.filter { $0.contains("circuit opened") }.count, 1)
        XCTAssertEqual(logs.filter { $0.contains("circuit reopened") }.count, 1)
    }

    func testReopenedCircuitEscalatesCooldownUpToTheCap() async {
        let clock = BrokerTestClock()
        let broker = makeBroker(clock: clock)
        var recoveryStates: [CaptureRequestBrokerRecoveryState] = []
        broker.recoveryStateDidChange = { recoveryStates.append($0) }

        _ = await captureError(from: broker, owner: UUID()) {
            throw self.falsePermissionDenial()
        }

        var expectedDelay = CaptureFailureRecovery.falsePermissionDenialDelay
        for _ in 0..<6 {
            clock.advance(by: expectedDelay)
            _ = await captureError(from: broker, owner: UUID()) {
                throw self.falsePermissionDenial()
            }
            expectedDelay = min(
                expectedDelay * 2,
                CaptureFailureRecovery.falsePermissionDenialMaximumDelay
            )

            let blocked = await captureError(from: broker, owner: UUID()) {
                XCTFail("An open circuit must not call the OS request")
            }
            XCTAssertEqual(
                blocked as? CaptureRequestBrokerError,
                .cooldown(untilMonotonicTime: clock.monotonicTime + expectedDelay)
            )
        }

        XCTAssertEqual(recoveryStates.last, .needsAttention)
    }

    func testMaximumCooldownRepublishesNeedsAttentionAfterCaptureRestart() async {
        let clock = BrokerTestClock()
        let broker = makeBroker(clock: clock)
        var recoveryStates: [CaptureRequestBrokerRecoveryState] = []
        broker.recoveryStateDidChange = { recoveryStates.append($0) }

        _ = await captureError(from: broker, owner: UUID()) {
            throw self.falsePermissionDenial()
        }

        var delay = CaptureFailureRecovery.falsePermissionDenialDelay
        while delay < CaptureFailureRecovery.falsePermissionDenialMaximumDelay {
            clock.advance(by: delay)
            _ = await captureError(from: broker, owner: UUID()) {
                throw self.falsePermissionDenial()
            }
            delay = min(
                delay * 2,
                CaptureFailureRecovery.falsePermissionDenialMaximumDelay
            )
        }

        recoveryStates.removeAll()
        _ = await captureError(from: broker, owner: UUID()) {
            XCTFail("A maximum-cooldown circuit must not call ScreenCaptureKit")
        }

        XCTAssertEqual(recoveryStates, [.needsAttention])
    }

    func testCoordinatorStartReadinessPrefersGlobalCooldownOverPartialCapture() {
        XCTAssertEqual(
            CaptureCoordinator.startReadiness(
                isCapturing: true,
                openCircuitDeadline: 1_234
            ),
            .coolingDown(untilMonotonicTime: 1_234)
        )
        XCTAssertEqual(
            CaptureCoordinator.startReadiness(
                isCapturing: true,
                openCircuitDeadline: nil
            ),
            .ready
        )
        XCTAssertEqual(
            CaptureCoordinator.startReadiness(
                isCapturing: false,
                openCircuitDeadline: nil
            ),
            .noDisplay
        )
    }

    func testCooldownRestartSchedulerCancellationSuppressesRetry() async {
        let sleepGate = BrokerTestGate()
        var retryCount = 0
        let scheduler = CaptureCooldownRestartScheduler { _ in
            await sleepGate.wait()
            try Task.checkCancellation()
        }

        scheduler.schedule(deadline: 100, delay: .seconds(1)) {
            retryCount += 1
        }
        await waitUntil { sleepGate.waiterCount == 1 }

        scheduler.cancel()
        sleepGate.resumeNext()
        await settleTasks()

        XCTAssertEqual(retryCount, 0)
        XCTAssertNil(scheduler.scheduledDeadline)
    }

    func testCooldownRestartSchedulerReplacesEarlierDeadline() async {
        let sleepGate = BrokerTestGate()
        var retries: [String] = []
        let scheduler = CaptureCooldownRestartScheduler { _ in
            await sleepGate.wait()
            try Task.checkCancellation()
        }

        scheduler.schedule(deadline: 100, delay: .seconds(1)) {
            retries.append("first")
        }
        await waitUntil { sleepGate.waiterCount == 1 }
        scheduler.schedule(deadline: 200, delay: .seconds(2)) {
            retries.append("second")
        }
        await waitUntil { sleepGate.waiterCount == 2 }

        sleepGate.resumeNext()
        sleepGate.resumeNext()
        await waitUntil { retries == ["second"] }

        XCTAssertEqual(retries, ["second"])
        XCTAssertNil(scheduler.scheduledDeadline)
    }

    func testCooldownRestartSchedulerPreservesReentrantReplacement() async {
        let sleepGate = BrokerTestGate()
        var retries: [String] = []
        let scheduler = CaptureCooldownRestartScheduler { _ in
            await sleepGate.wait()
            try Task.checkCancellation()
        }

        scheduler.schedule(deadline: 100, delay: .seconds(1)) {
            retries.append("first")
            scheduler.schedule(deadline: 200, delay: .seconds(2)) {
                retries.append("second")
            }
        }
        await waitUntil { sleepGate.waiterCount == 1 }
        sleepGate.resumeNext()
        await waitUntil {
            retries == ["first"] && scheduler.scheduledDeadline == 200
                && sleepGate.waiterCount == 1
        }

        sleepGate.resumeNext()
        await waitUntil { retries == ["first", "second"] }

        XCTAssertNil(scheduler.scheduledDeadline)
    }

    func testQuickRelapseAfterRecoveryEscalatesCooldown() async throws {
        let clock = BrokerTestClock()
        let broker = makeBroker(clock: clock)

        _ = await captureError(from: broker, owner: UUID()) {
            throw self.falsePermissionDenial()
        }
        clock.advance(by: CaptureFailureRecovery.falsePermissionDenialDelay)
        try await broker.perform(owner: UUID()) {}

        // Capture worked briefly, then the same episode resumed well inside
        // the escalation reset window.
        clock.advance(by: 20)
        _ = await captureError(from: broker, owner: UUID()) {
            throw self.falsePermissionDenial()
        }

        let blocked = await captureError(from: broker, owner: UUID()) {
            XCTFail("An open circuit must not call the OS request")
        }
        XCTAssertEqual(
            blocked as? CaptureRequestBrokerError,
            .cooldown(
                untilMonotonicTime: clock.monotonicTime
                    + CaptureFailureRecovery.falsePermissionDenialDelay * 2
            )
        )
    }

    func testDelayedFailedProbeStillEscalatesCooldown() async {
        let clock = BrokerTestClock()
        let broker = makeBroker(clock: clock)

        _ = await captureError(from: broker, owner: UUID()) {
            throw self.falsePermissionDenial()
        }

        // The probe was delayed long past the reset interval (e.g. the Mac
        // slept through the cooldown). No healthy capture happened, so the
        // failed probe must still escalate rather than reset to the base.
        clock.advance(
            by: CaptureFailureRecovery.falsePermissionDenialDelay
                + CaptureFailureRecovery.falsePermissionDenialEscalationResetInterval + 100
        )
        _ = await captureError(from: broker, owner: UUID()) {
            throw self.falsePermissionDenial()
        }

        let blocked = await captureError(from: broker, owner: UUID()) {
            XCTFail("An open circuit must not call the OS request")
        }
        XCTAssertEqual(
            blocked as? CaptureRequestBrokerError,
            .cooldown(
                untilMonotonicTime: clock.monotonicTime
                    + CaptureFailureRecovery.falsePermissionDenialDelay * 2
            )
        )
    }

    func testQuickRelapseAfterDelayedRecoveryStillEscalates() async throws {
        let clock = BrokerTestClock()
        let broker = makeBroker(clock: clock)

        _ = await captureError(from: broker, owner: UUID()) {
            throw self.falsePermissionDenial()
        }

        // The successful probe ran long after the cooldown deadline (e.g.
        // after sleep). The healthy period starts at that recovery, so a
        // relapse moments later is the same episode and must escalate.
        clock.advance(
            by: CaptureFailureRecovery.falsePermissionDenialDelay
                + CaptureFailureRecovery.falsePermissionDenialEscalationResetInterval + 100
        )
        try await broker.perform(owner: UUID()) {}

        clock.advance(by: 10)
        _ = await captureError(from: broker, owner: UUID()) {
            throw self.falsePermissionDenial()
        }

        let blocked = await captureError(from: broker, owner: UUID()) {
            XCTFail("An open circuit must not call the OS request")
        }
        XCTAssertEqual(
            blocked as? CaptureRequestBrokerError,
            .cooldown(
                untilMonotonicTime: clock.monotonicTime
                    + CaptureFailureRecovery.falsePermissionDenialDelay * 2
            )
        )
    }

    func testEscalationResetsAfterSustainedRecovery() async throws {
        let clock = BrokerTestClock()
        let broker = makeBroker(clock: clock)

        _ = await captureError(from: broker, owner: UUID()) {
            throw self.falsePermissionDenial()
        }
        clock.advance(by: CaptureFailureRecovery.falsePermissionDenialDelay)
        _ = await captureError(from: broker, owner: UUID()) {
            throw self.falsePermissionDenial()
        }
        clock.advance(by: CaptureFailureRecovery.falsePermissionDenialDelay * 2)
        try await broker.perform(owner: UUID()) {}

        // A healthy stretch longer than the reset interval means the next
        // denial is a fresh episode and starts from the base cooldown again.
        clock.advance(
            by: CaptureFailureRecovery.falsePermissionDenialEscalationResetInterval + 1
        )
        _ = await captureError(from: broker, owner: UUID()) {
            throw self.falsePermissionDenial()
        }

        let blocked = await captureError(from: broker, owner: UUID()) {
            XCTFail("An open circuit must not call the OS request")
        }
        XCTAssertEqual(
            blocked as? CaptureRequestBrokerError,
            .cooldown(
                untilMonotonicTime: clock.monotonicTime
                    + CaptureFailureRecovery.falsePermissionDenialDelay
            )
        )
    }

    func testCancelledHalfOpenProbeKeepsSharedCircuitOpen() async {
        let clock = BrokerTestClock()
        let broker = makeBroker(clock: clock)
        let gate = BrokerTestGate()

        _ = await captureError(from: broker, owner: UUID()) {
            throw self.falsePermissionDenial()
        }
        clock.advance(by: CaptureFailureRecovery.falsePermissionDenialDelay)

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
            .cooldown(
                untilMonotonicTime: clock.monotonicTime
                    + CaptureFailureRecovery.falsePermissionDenialDelay
            )
        )
    }

    func testCancelledHalfOpenProbeWithSuccessfulOSCallKeepsSharedCircuitOpen() async {
        let clock = BrokerTestClock()
        let broker = makeBroker(clock: clock)
        let gate = BrokerTestGate()

        _ = await captureError(from: broker, owner: UUID()) {
            throw self.falsePermissionDenial()
        }
        clock.advance(by: CaptureFailureRecovery.falsePermissionDenialDelay)

        let probe = Task { @MainActor () -> Error? in
            await self.captureError(from: broker, owner: UUID()) {
                // The OS call returns successfully even though the probe's
                // task was cancelled while it was in flight.
                await gate.wait()
            }
        }
        await waitUntil { gate.waiterCount == 1 }

        probe.cancel()
        gate.resumeNext()
        let probeError = await probe.value
        XCTAssertTrue(probeError is CancellationError)

        let otherOwnerError = await captureError(from: broker, owner: UUID()) {
            XCTFail("A cancelled probe must not close the shared circuit even when its OS call succeeded")
        }
        XCTAssertEqual(
            otherOwnerError as? CaptureRequestBrokerError,
            .cooldown(
                untilMonotonicTime: clock.monotonicTime
                    + CaptureFailureRecovery.falsePermissionDenialDelay
            )
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
            try await broker.perform(owner: firstOwner) {
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
            try await broker.perform(owner: survivingOwner) {
                started.append("surviving")
                return "surviving"
            }
        }
        await waitUntil { broker.queuedRequestCountForTesting == 2 }

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
            .cooldown(
                untilMonotonicTime: clock.monotonicTime
                    + CaptureFailureRecovery.falsePermissionDenialDelay
            )
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

        try await broker.perform(owner: UUID()) {
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

        try await broker.perform(owner: UUID()) {
            nextRequestCalls += 1
        }
        XCTAssertEqual(nextRequestCalls, 1)
    }

    func testPeriodicRequestWaitsBehindActiveRequest() async throws {
        let clock = BrokerTestClock()
        let broker = makeBroker(clock: clock)
        let gate = BrokerTestGate()
        var periodicCalls = 0

        let active = Task { @MainActor () throws -> Void in
            try await broker.perform(owner: UUID()) {
                await gate.wait()
            }
        }
        await waitUntil { gate.waiterCount == 1 }

        let periodic = Task { @MainActor () throws -> Void in
            try await broker.perform(owner: UUID()) {
                periodicCalls += 1
            }
        }
        await waitUntil { broker.queuedRequestCountForTesting == 1 }
        XCTAssertEqual(periodicCalls, 0)

        gate.resumeNext()
        try await active.value
        try await periodic.value
        XCTAssertEqual(periodicCalls, 1)
    }

    func testThreeAlignedPeriodicOwnersRunInFIFOOrder() async throws {
        let clock = BrokerTestClock()
        let broker = makeBroker(clock: clock)
        let gate = BrokerTestGate()
        let firstOwner = UUID()
        let secondOwner = UUID()
        let thirdOwner = UUID()
        var calls: [String] = []

        let first = Task { @MainActor () throws -> Void in
            try await broker.perform(owner: firstOwner) {
                calls.append("first")
                await gate.wait()
            }
        }
        await waitUntil { gate.waiterCount == 1 }

        let second = Task { @MainActor () throws -> Void in
            try await broker.perform(owner: secondOwner) {
                calls.append("second")
            }
        }
        await waitUntil { broker.queuedRequestCountForTesting == 1 }
        let third = Task { @MainActor () throws -> Void in
            try await broker.perform(owner: thirdOwner) {
                calls.append("third")
            }
        }
        await waitUntil { broker.queuedRequestCountForTesting == 2 }
        XCTAssertEqual(calls, ["first"])

        gate.resumeNext()
        try await first.value
        try await second.value
        try await third.value
        XCTAssertEqual(calls, ["first", "second", "third"])
    }

    func testCooldownDeadlineUsesMonotonicTime() async {
        let clock = BrokerTestClock()
        let broker = makeBroker(clock: clock)
        var calls = 0
        let expectedDeadline = clock.monotonicTime
            + CaptureFailureRecovery.falsePermissionDenialDelay

        _ = await captureError(from: broker, owner: UUID()) {
            throw self.falsePermissionDenial()
        }
        clock.advance(by: CaptureFailureRecovery.falsePermissionDenialDelay / 2)

        let error = await captureError(from: broker, owner: UUID()) {
            calls += 1
        }

        XCTAssertEqual(calls, 0)
        XCTAssertEqual(
            error as? CaptureRequestBrokerError,
            .cooldown(untilMonotonicTime: expectedDeadline)
        )
    }

    func testRecoveryStateReportsCooldownAndRecovery() async throws {
        let clock = BrokerTestClock()
        let broker = makeBroker(clock: clock)
        var states: [CaptureRequestBrokerRecoveryState] = []
        broker.recoveryStateDidChange = { states.append($0) }

        _ = await captureError(from: broker, owner: UUID()) {
            throw self.falsePermissionDenial()
        }
        XCTAssertEqual(states, [.coolingDown])

        clock.advance(by: CaptureFailureRecovery.falsePermissionDenialDelay)
        try await broker.perform(owner: UUID()) {}
        XCTAssertEqual(states.last, .normal)
    }

    func testOpenCircuitRepublishesRecoveryStateAfterCaptureRestart() async {
        let clock = BrokerTestClock()
        let broker = makeBroker(clock: clock)
        var states: [CaptureRequestBrokerRecoveryState] = []
        broker.recoveryStateDidChange = { states.append($0) }

        _ = await captureError(from: broker, owner: UUID()) {
            throw self.falsePermissionDenial()
        }
        states.removeAll()

        _ = await captureError(from: broker, owner: UUID()) {
            XCTFail("An open circuit must not call the OS request")
        }

        XCTAssertEqual(states, [.coolingDown])
    }

    func testFailedHalfOpenProbeDoesNotReportHealthyUntilSuccess() async throws {
        let clock = BrokerTestClock()
        let broker = makeBroker(clock: clock)
        var states: [CaptureRequestBrokerRecoveryState] = []
        broker.recoveryStateDidChange = { states.append($0) }

        _ = await captureError(from: broker, owner: UUID()) {
            throw self.falsePermissionDenial()
        }
        clock.advance(by: CaptureFailureRecovery.falsePermissionDenialDelay)

        _ = await captureError(from: broker, owner: UUID()) {
            throw NSError(
                domain: "com.apple.ScreenCaptureKit.CoreGraphicsErrorDomain",
                code: 1004
            )
        }
        XCTAssertEqual(states, [.coolingDown])

        try await broker.perform(owner: UUID()) {}
        XCTAssertEqual(states.last, .normal)
    }

    func testCancellingAllQueuedOwnersBeforeActiveCompletionPreventsHandoff() async {
        let clock = BrokerTestClock()
        let broker = makeBroker(clock: clock)
        let activeOwner = UUID()
        let secondOwner = UUID()
        let thirdOwner = UUID()
        let gate = BrokerTestGate()
        var started: [String] = []

        let active = Task { @MainActor () -> Error? in
            await captureError(from: broker, owner: activeOwner) {
                started.append("active")
                await gate.wait()
                try Task.checkCancellation()
            }
        }
        await waitUntil { gate.waiterCount == 1 }

        let second = Task { @MainActor () -> Error? in
            await captureError(from: broker, owner: secondOwner) {
                started.append("second")
            }
        }
        let third = Task { @MainActor () -> Error? in
            await captureError(from: broker, owner: thirdOwner) {
                started.append("third")
            }
        }
        await waitUntil { broker.queuedRequestCountForTesting == 2 }

        active.cancel()
        broker.cancelRequests(for: activeOwner)
        broker.cancelRequests(for: secondOwner)
        broker.cancelRequests(for: thirdOwner)
        gate.resumeNext()

        let activeError = await active.value
        let secondError = await second.value
        let thirdError = await third.value
        XCTAssertTrue(activeError is CancellationError)
        XCTAssertTrue(secondError is CancellationError)
        XCTAssertTrue(thirdError is CancellationError)
        XCTAssertEqual(started, ["active"])
    }

    private func makeBroker(
        clock: BrokerTestClock,
        hasScreenRecordingPermission: Bool = true,
        log: @escaping @MainActor (String) -> Void = { _ in }
    ) -> CaptureRequestBroker {
        CaptureRequestBroker(
            monotonicNow: { clock.monotonicTime },
            hasScreenRecordingPermission: { hasScreenRecordingPermission },
            log: log
        )
    }

    private func captureError(
        from broker: CaptureRequestBroker,
        owner: UUID,
        operation: @escaping @MainActor () async throws -> Void
    ) async -> Error? {
        do {
            try await broker.perform(owner: owner, operation: operation)
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
    var monotonicTime: TimeInterval = 1_000

    func advance(by interval: TimeInterval) {
        monotonicTime += interval
    }
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
