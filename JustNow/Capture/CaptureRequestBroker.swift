//
//  CaptureRequestBroker.swift
//  JustNow
//

import CoreGraphics
import Foundation
import os.log

private let captureBrokerLogger = Logger(subsystem: "sg.tk.JustNow", category: "Capture")

/// The reason a one-shot request was not allowed to reach ScreenCaptureKit.
/// These are expected, temporary results and must not count as capture errors.
enum CaptureRequestBrokerError: Error, Equatable {
    /// A false ScreenCaptureKit permission denial opened the process-wide circuit.
    case cooldown(untilMonotonicTime: TimeInterval)
}

enum CaptureRequestBrokerRecoveryState: Equatable {
    case normal
    case coolingDown
}

/// Serialises all one-shot ScreenCaptureKit calls made by this process.
///
/// ScreenCaptureKit can momentarily return `SCStreamErrorDomain/-3801` even
/// when TCC remains granted. The broker sees that result before releasing a
/// waiting display, opens one shared circuit, and makes callers fail fast
/// until a single half-open probe succeeds.
@MainActor
final class CaptureRequestBroker {
    private struct Waiter {
        let id: UUID
        let owner: UUID
        let continuation: CheckedContinuation<WaitResult, Never>
    }

    private enum WaitResult {
        case acquired
        case cancelled
        case cooldown(TimeInterval)
    }

    private enum CircuitState {
        case closed
        case open(monotonicDeadline: TimeInterval)
        case halfOpen
    }

    private let monotonicNow: @MainActor () -> TimeInterval
    private let hasScreenRecordingPermission: @MainActor () -> Bool
    private let log: @MainActor (String) -> Void
    private let cooldown: TimeInterval

    var recoveryStateDidChange: @MainActor (CaptureRequestBrokerRecoveryState) -> Void = { _ in }

    private var circuitState: CircuitState = .closed
    private var isRequestInFlight = false
    private var waiters: [Waiter] = []
    private var openedCircuitCount = 0

    init(
        monotonicNow: @escaping @MainActor () -> TimeInterval = {
            TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        },
        hasScreenRecordingPermission: @escaping @MainActor () -> Bool = {
            ScreenCaptureManager.hasScreenRecordingPermission()
        },
        cooldown: TimeInterval = CaptureFailureRecovery.falsePermissionDenialDelay,
        log: @escaping @MainActor (String) -> Void = { message in
            captureBrokerLogger.warning("\(message, privacy: .public)")
            DiagnosticsLog.shared.log("Capture", message)
        }
    ) {
        self.monotonicNow = monotonicNow
        self.hasScreenRecordingPermission = hasScreenRecordingPermission
        self.cooldown = cooldown
        self.log = log
    }

    /// Runs a single one-shot request after process-wide admission.
    ///
    /// Each manager's periodic loop is serial, so waiting here preserves the
    /// configured per-display cadence without allowing stale per-owner work to
    /// accumulate. Interactive refreshes use the same FIFO admission path.
    func perform<Value>(
        owner: UUID,
        operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        try await acquireTurn(owner: owner)

        do {
            let value = try await operation()
            finishTurn(after: .success)
            return value
        } catch {
            finishTurn(after: .failure(error))
            throw error
        }
    }

    /// Removes only requests owned by the manager being stopped or unplugged.
    /// It deliberately does not mutate a shared circuit or another manager's
    /// work.
    func cancelRequests(for owner: UUID) {
        let matching = waiters.filter { $0.owner == owner }
        waiters.removeAll { $0.owner == owner }
        for waiter in matching {
            waiter.continuation.resume(returning: .cancelled)
        }
    }

    // MARK: - Admission

    private func acquireTurn(owner: UUID) async throws {
        try Task.checkCancellation()

        if case .open(let monotonicDeadline) = circuitState {
            guard monotonicNow() >= monotonicDeadline else {
                // Capture may have been paused and restarted while the shared
                // circuit was still open. Re-publish the state so the new run
                // does not briefly present itself as healthy.
                recoveryStateDidChange(.coolingDown)
                throw CaptureRequestBrokerError.cooldown(
                    untilMonotonicTime: monotonicDeadline
                )
            }
            // The first request after expiry is the only half-open probe. It
            // cannot race another request because the broker is main-actor
            // isolated and an open circuit never releases queued work.
            circuitState = .halfOpen
        }

        if isRequestInFlight {
            try await waitForTurn(owner: owner)
            return
        }

        isRequestInFlight = true
    }

    private func waitForTurn(owner: UUID) async throws {
        let id = UUID()
        let result = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<WaitResult, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                waiters.append(Waiter(id: id, owner: owner, continuation: continuation))
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(id: id)
            }
        })

        switch result {
        case .acquired:
            return
        case .cancelled:
            throw CancellationError()
        case .cooldown(let monotonicDeadline):
            throw CaptureRequestBrokerError.cooldown(
                untilMonotonicTime: monotonicDeadline
            )
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: .cancelled)
    }

    // MARK: - Completion

    private enum TurnOutcome {
        case success
        case failure(Error)
    }

    private func finishTurn(after outcome: TurnOutcome) {
        switch outcome {
        case .success:
            if case .halfOpen = circuitState {
                circuitState = .closed
                logCircuitRecovery()
                recoveryStateDidChange(.normal)
            }
            releaseNextWaiter()

        case .failure(let error):
            let recovery = CaptureFailureRecovery.disposition(
                for: error,
                hasScreenRecordingPermission: hasScreenRecordingPermission()
            )
            if case .backOff(let delay) = recovery {
                let isHalfOpenProbe: Bool
                if case .halfOpen = circuitState {
                    isHalfOpenProbe = true
                } else {
                    isHalfOpenProbe = false
                }
                openCircuit(for: delay, isReopen: isHalfOpenProbe)
                return
            }

            if case .halfOpen = circuitState {
                if error is CancellationError {
                    // A display disappearing during the probe must not let it
                    // reset the circuit for every other display. Keep the
                    // shared protection in place and retry with a future owner.
                    openCircuit(for: cooldown, isReopen: true)
                    return
                }
                // This was not the beta false-denial signature. Preserve the
                // manager's normal error handling and let later requests run,
                // but remain half-open until a capture actually succeeds.
            }
            releaseNextWaiter()
        }
    }

    private func openCircuit(for delay: TimeInterval, isReopen: Bool = false) {
        let monotonicDeadline = monotonicNow() + delay
        circuitState = .open(monotonicDeadline: monotonicDeadline)
        openedCircuitCount += 1

        let queuedCount = waiters.count
        let event = isReopen ? "reopened" : "opened"
        log(
            "Global ScreenCaptureKit capture circuit \(event) for \(delay) seconds "
                + "(queuedRequests=\(queuedCount), circuitOpenCount=\(openedCircuitCount))"
        )
        recoveryStateDidChange(.coolingDown)

        let pending = waiters
        waiters.removeAll()
        isRequestInFlight = false
        for waiter in pending {
            waiter.continuation.resume(returning: .cooldown(monotonicDeadline))
        }
    }

    private func releaseNextWaiter() {
        guard !waiters.isEmpty else {
            isRequestInFlight = false
            return
        }

        let waiter = waiters.removeFirst()
        // Keep the permit held while the waiter resumes, so no unrelated
        // caller can steal it before the queued request starts its OS call.
        waiter.continuation.resume(returning: .acquired)
    }

    private func logCircuitRecovery() {
        log(
            "Global ScreenCaptureKit capture circuit recovered "
                + "(queuedRequests=\(waiters.count), circuitOpenCount=\(openedCircuitCount))"
        )
    }

#if DEBUG
    var queuedRequestCountForTesting: Int {
        waiters.count
    }
#endif
}
