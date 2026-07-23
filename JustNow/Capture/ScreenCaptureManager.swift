//
//  ScreenCaptureManager.swift
//  JustNow
//

@preconcurrency import ScreenCaptureKit
import AppKit
import CoreVideo
import os.log

private let captureLogger = Logger(subsystem: "sg.tk.JustNow", category: "Capture")

enum CaptureError: Error {
    case permissionDenied
    case noDisplay
}

enum ScreenshotCaptureExecution {
    private actor RequestGate {
        private struct Waiter {
            let id: UUID
            let continuation: CheckedContinuation<Void, Error>
        }

        private var isHeld = false
        private var waiters: [Waiter] = []

        func withPermit<T: Sendable>(
            id: UUID,
            cancellation: RequestCancellation,
            waiterDidEnqueue: (@Sendable () -> Void)?,
            _ operation: @escaping @Sendable () async throws -> T
        ) async throws -> T {
            try cancellation.check()
            try await acquire(
                id: id,
                cancellation: cancellation,
                waiterDidEnqueue: waiterDidEnqueue
            )
            defer { release() }
            try cancellation.check()
            return try await operation()
        }

        func cancel(id: UUID) {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else {
                return
            }
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        }

        private func acquire(
            id: UUID,
            cancellation: RequestCancellation,
            waiterDidEnqueue: (@Sendable () -> Void)?
        ) async throws {
            // Actor serialisation makes this check-and-enqueue atomic with
            // cancel(id:), closing the cancel-before-enqueue race.
            try cancellation.check()
            guard isHeld else {
                isHeld = true
                return
            }
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
                waiterDidEnqueue?()
            }
        }

        private func release() {
            guard !waiters.isEmpty else {
                isHeld = false
                return
            }
            waiters.removeFirst().continuation.resume()
        }
    }

    private nonisolated final class RequestCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var isCancelled = false

        func cancel() {
            lock.lock()
            isCancelled = true
            lock.unlock()
        }

        func check() throws {
            lock.lock()
            let isCancelled = self.isCancelled
            lock.unlock()
            if isCancelled {
                throw CancellationError()
            }
        }
    }

    private nonisolated final class CancellationRace<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var resolvedResult: Result<T, Error>?

        /// Returns false when cancellation won before the continuation was
        /// installed, so the caller can avoid starting unnecessary OS work.
        func install(_ continuation: CheckedContinuation<T, Error>) -> Bool {
            lock.lock()
            if let resolvedResult {
                lock.unlock()
                continuation.resume(with: resolvedResult)
                return false
            }
            self.continuation = continuation
            lock.unlock()
            return true
        }

        func resolve(_ result: Result<T, Error>) {
            lock.lock()
            guard resolvedResult == nil else {
                lock.unlock()
                return
            }
            resolvedResult = result
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }

    private nonisolated static let requestGate = RequestGate()

    private struct SendableFilter: @unchecked Sendable {
        let value: SCContentFilter
    }

    nonisolated static func run<T: Sendable>(
        waiterDidEnqueue: (@Sendable () -> Void)? = nil,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let requestID = UUID()
        let cancellation = RequestCancellation()
        let race = CancellationRace<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard race.install(continuation) else { return }
                Task.detached(priority: .userInitiated) {
                    let result: Result<T, Error>
                    do {
                        result = .success(
                            try await requestGate.withPermit(
                                id: requestID,
                                cancellation: cancellation,
                                waiterDidEnqueue: waiterDidEnqueue,
                                operation
                            )
                        )
                    } catch {
                        result = .failure(error)
                    }
                    race.resolve(result)
                }
            }
        } onCancel: {
            cancellation.cancel()
            race.resolve(.failure(CancellationError()))
            Task {
                await requestGate.cancel(id: requestID)
            }
        }
    }

    nonisolated static func captureImage(
        contentFilter: SCContentFilter,
        outputDimensions: (width: Int, height: Int)
    ) async throws -> CGImage {
        let filter = SendableFilter(value: contentFilter)
        return try await run {
            if #available(macOS 26.0, *) {
                let configuration = SCScreenshotConfiguration()
                configuration.width = outputDimensions.width
                configuration.height = outputDimensions.height
                configuration.showsCursor = true
                configuration.dynamicRange = .sdr

                let output = try await SCScreenshotManager.captureScreenshot(
                    contentFilter: filter.value,
                    configuration: configuration
                )
                guard let image = output.sdrImage else {
                    throw ScreenshotCaptureError.missingImage
                }
                return image
            }

            let configuration = SCStreamConfiguration()
            configuration.width = outputDimensions.width
            configuration.height = outputDimensions.height
            configuration.showsCursor = true
            configuration.capturesAudio = false
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.colorSpaceName = CGColorSpace.sRGB
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter.value,
                configuration: configuration
            )
        }
    }
}

private enum ScreenshotCaptureError: Error {
    case missingImage
}

enum CaptureFailureRecovery: Equatable {
    case countTowardsStop
    case backOff(TimeInterval)

    nonisolated static let falsePermissionDenialDelay: TimeInterval = 30
    /// Upper bound for the shared circuit's escalating cooldown. A sustained
    /// OS-side desync should settle into one probe every ten minutes instead
    /// of touching ScreenCaptureKit twice a minute forever.
    nonisolated static let falsePermissionDenialMaximumDelay: TimeInterval = 600
    /// A circuit that reopens within this interval of the previous cooldown's
    /// end is treated as the same desync episode and escalates the next
    /// cooldown; a longer healthy stretch resets escalation to the base delay.
    nonisolated static let falsePermissionDenialEscalationResetInterval: TimeInterval = 300

    /// True when the error is ScreenCaptureKit's TCC denial signature,
    /// regardless of whether preflight considers the denial genuine.
    nonisolated static func isPermissionDenial(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain"
            && nsError.code == -3801
    }

    nonisolated static func disposition(
        for error: Error,
        hasScreenRecordingPermission: Bool
    ) -> CaptureFailureRecovery {
        guard hasScreenRecordingPermission, isPermissionDenial(error) else {
            return .countTowardsStop
        }

        // On current macOS betas, ScreenCaptureKit can briefly report that the
        // user declined capture while CoreGraphics and tccd still say the app
        // is authorised. Rapid retries make that OS-side mismatch worse and
        // can surface another native permission prompt. Leave the existing
        // capture session intact and give replayd time to settle instead.
        return .backOff(falsePermissionDenialDelay)
    }
}

@MainActor
protocol ScreenCaptureDelegate: AnyObject {
    func captureManager(_ manager: ScreenCaptureManager, didCaptureFrame image: CGImage, at timestamp: Date)
    func captureManagerDidStop(_ manager: ScreenCaptureManager)
}

/// Uses SCScreenshotManager for one-shot captures instead of SCStream.
/// This avoids the persistent purple "sharing" indicator in the menu bar.
@MainActor
class ScreenCaptureManager: NSObject {
    private let maximumConsecutiveCaptureFailures = 3

    private var filter: SCContentFilter?
    private var displayDimensions: (width: Int, height: Int)?
    private var captureOutputDimensions: (width: Int, height: Int)?
    private var displayBackingScale: CGFloat = 1
    private var captureScale: Int = 2

    weak var delegate: ScreenCaptureDelegate?
    private(set) var isCapturing = false
    private(set) var captureInterval: TimeInterval = 1.0
    let targetDisplayID: CGDirectDisplayID
    private let captureRequestBroker: CaptureRequestBroker
    private let captureRequestOwner = UUID()

    init(targetDisplayID: CGDirectDisplayID, captureRequestBroker: CaptureRequestBroker) {
        self.targetDisplayID = targetDisplayID
        self.captureRequestBroker = captureRequestBroker
        super.init()
    }

    /// Serial loop: each capture completes before the next is scheduled.
    private var captureLoopTask: Task<Void, Never>?
    /// Bumped on stop and on each new loop so a superseded loop cannot clear `captureLoopTask`.
    private var captureLoopSerial = 0
    /// Bumped whenever the desired cadence changes so the live loop can adopt a new deadline without restarting.
    private var captureScheduleRevision = 0
    private var nextCaptureAt: Date?
    private var captureCooldownDeadline: TimeInterval?
    private var captureWakeTask: Task<Void, Never>?
    private var captureWakeContinuation: CheckedContinuation<Void, Never>?
    private var consecutiveCaptureFailures = 0

    static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func startCapture() async throws {
        // Stop any existing capture
        let previousLoop = stopCaptureLoop()
        await previousLoop?.value
        try Task.checkCancellation()

        // Permission requests are handled by the app launch flow so we do not
        // trigger a second overlapping prompt while starting capture.
        guard Self.hasScreenRecordingPermission() else {
            DiagnosticsLog.shared.log(
                "Capture",
                "Start blocked for display \(targetDisplayID): screen recording preflight returned denied; \(CaptureSystemState.summary())"
            )
            throw CaptureError.permissionDenied
        }

        // Route content discovery through the shared broker so a start attempt
        // during a false-denial cooldown fails fast instead of touching
        // ScreenCaptureKit and risking another native permission prompt.
        let content: SCShareableContent
        do {
            content = try await captureRequestBroker.perform(owner: captureRequestOwner) {
                try await ScreenshotCaptureExecution.run {
                    try await SCShareableContent.excludingDesktopWindows(
                        false,
                        onScreenWindowsOnly: true
                    )
                }
            }
        } catch {
            // Permission can be revoked between the preflight above and the
            // ScreenCaptureKit call. Surface that as a typed permission error
            // so callers show the permission flow instead of a generic failure.
            if CaptureFailureRecovery.isPermissionDenial(error), !Self.hasScreenRecordingPermission() {
                DiagnosticsLog.shared.log(
                    "Capture",
                    "Start failed for display \(targetDisplayID): screen recording permission revoked during content discovery; \(CaptureSystemState.summary())"
                )
                throw CaptureError.permissionDenied
            }
            throw error
        }
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == targetDisplayID }) else {
            throw CaptureError.noDisplay
        }

        let dimensions = (width: display.width, height: display.height)
        displayBackingScale = Self.backingScale(for: targetDisplayID)
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let outputDimensions = captureDimensions(for: dimensions)
        try Task.checkCancellation()

        self.filter = filter
        displayDimensions = dimensions
        captureOutputDimensions = outputDimensions

        consecutiveCaptureFailures = 0
        isCapturing = true
        captureScheduleRevision += 1
        nextCaptureAt = Date()
        scheduleCaptureLoop()

        captureLogger.info("Capture started successfully (one-shot mode) for display \(self.targetDisplayID, privacy: .public)")
    }

    func stopCapture() async {
        let previousLoop = beginStoppingCapture()
        await previousLoop?.value
    }

    /// Cancels this manager and its broker-owned waiters synchronously. The
    /// coordinator uses this for two-phase shutdown so no queued display can
    /// start another OS request while an earlier display is being awaited.
    func beginStoppingCapture() -> Task<Void, Never>? {
        stopCaptureLoop()
    }

    private func stopCaptureLoop() -> Task<Void, Never>? {
        let previousLoop = captureLoopTask
        let wasCapturing = isCapturing || previousLoop != nil
        captureLoopSerial += 1
        captureScheduleRevision += 1
        isCapturing = false
        consecutiveCaptureFailures = 0
        nextCaptureAt = nil
        captureCooldownDeadline = nil
        captureLoopTask = nil
        previousLoop?.cancel()
        captureRequestBroker.cancelRequests(for: captureRequestOwner)
        wakeCaptureLoop()
        if wasCapturing {
            captureLogger.info("Capture stopped")
        }
        return previousLoop
    }

    func updateCaptureInterval(_ interval: TimeInterval) {
        captureInterval = interval
        guard isCapturing else { return }
        captureScheduleRevision += 1
        nextCaptureAt = Date().addingTimeInterval(interval)
        if captureLoopTask == nil {
            scheduleCaptureLoop()
        } else {
            wakeCaptureLoop()
        }
    }

    func updateCaptureScale(_ scale: Int) {
        captureScale = max(1, scale)
        guard let displayDimensions else { return }
        captureOutputDimensions = captureDimensions(for: displayDimensions)
    }

    /// Capture a single frame immediately and return it (for overlay open).
    func captureNow() async -> CGImage? {
        let requestLoopSerial = captureLoopSerial
        guard isCapturing else { return nil }
        return try? await captureImageSerially(
            expectedLoopSerial: requestLoopSerial
        )
    }

    // MARK: - Private

    private func scheduleCaptureLoop() {
        guard isCapturing else { return }
        guard captureLoopTask == nil else { return }
        captureLoopSerial += 1
        let serial = captureLoopSerial
        captureLoopTask = Task { [weak self] in
            guard let self else { return }
            await self.runPeriodicCaptureLoop(loopSerial: serial)
        }
    }

    private func runPeriodicCaptureLoop(loopSerial: Int) async {
        while !Task.isCancelled, isCapturing {
            if let captureCooldownDeadline {
                let remaining = captureCooldownDeadline - Self.monotonicTime()
                if remaining > 0 {
                    await waitForCaptureWake(for: remaining)
                    continue
                }
                self.captureCooldownDeadline = nil
                nextCaptureAt = Date()
            }

            let now = Date()
            let deadline = nextCaptureAt ?? now
            if deadline > now {
                await waitForCaptureWake(until: deadline)
                continue
            }

            let tickStart = now
            let scheduleRevision = captureScheduleRevision
            await captureSingleFrameAndDeliver(loopSerial: loopSerial)
            guard isCapturing, !Task.isCancelled else { break }

            if captureScheduleRevision == scheduleRevision {
                nextCaptureAt = tickStart.addingTimeInterval(captureInterval)
            } else if let nextCaptureAt, nextCaptureAt <= Date() {
                self.nextCaptureAt = Date().addingTimeInterval(captureInterval)
            }
        }
        guard loopSerial == captureLoopSerial else { return }
        wakeCaptureLoop()
        nextCaptureAt = nil
        captureLoopTask = nil
    }

    private func waitForCaptureWake(until deadline: Date) async {
        let delay = deadline.timeIntervalSinceNow
        guard delay > 0 else { return }

        await waitForCaptureWake(for: delay)
    }

    private func waitForCaptureWake(for delay: TimeInterval) async {
        guard delay > 0 else { return }

        await withCheckedContinuation { continuation in
            guard isCapturing else {
                continuation.resume()
                return
            }

            captureWakeContinuation = continuation
            captureWakeTask?.cancel()
            captureWakeTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self.resumeCaptureWakeIfNeeded()
            }
        }
    }

    private func wakeCaptureLoop() {
        captureWakeTask?.cancel()
        captureWakeTask = nil
        resumeCaptureWakeIfNeeded()
    }

    private func resumeCaptureWakeIfNeeded() {
        captureWakeTask = nil
        guard let continuation = captureWakeContinuation else { return }
        captureWakeContinuation = nil
        continuation.resume()
    }

    private func captureImageSerially(
        expectedLoopSerial: Int? = nil
    ) async throws -> CGImage {
        let image = try await captureRequestBroker.perform(
            owner: captureRequestOwner
        ) { [weak self] in
            guard let self else { throw CancellationError() }
            try Task.checkCancellation()
            guard let filter = self.filter, let outputDimensions = self.captureOutputDimensions else {
                throw CancellationError()
            }
            if let expectedLoopSerial {
                guard self.isCapturing, self.captureLoopSerial == expectedLoopSerial else {
                    throw CancellationError()
                }
            }

            let image = try await ScreenshotCaptureExecution.captureImage(
                contentFilter: filter,
                outputDimensions: outputDimensions
            )
            // Keep cancellation inside the brokered operation. If a display
            // disappears while a half-open probe is in ScreenCaptureKit, a
            // late successful return must not close the global circuit.
            try Task.checkCancellation()
            if let expectedLoopSerial {
                guard self.isCapturing, self.captureLoopSerial == expectedLoopSerial else {
                    throw CancellationError()
                }
            }
            return image
        }
        try Task.checkCancellation()
        if let expectedLoopSerial {
            guard isCapturing, captureLoopSerial == expectedLoopSerial else {
                throw CancellationError()
            }
        }
        return image
    }

    private func captureSingleFrameAndDeliver(loopSerial: Int) async {
        guard isCapturing, !Task.isCancelled, loopSerial == captureLoopSerial else { return }
        do {
            let image = try await captureImageSerially(
                expectedLoopSerial: loopSerial
            )
            guard isCapturing, !Task.isCancelled, loopSerial == captureLoopSerial else { return }
            consecutiveCaptureFailures = 0
            let timestamp = Date()
            delegate?.captureManager(self, didCaptureFrame: image, at: timestamp)
        } catch let error as CaptureRequestBrokerError {
            handleCaptureRequestDeferral(error, loopSerial: loopSerial)
        } catch is CancellationError {
            // Expected when stopping capture.
        } catch {
            handleCaptureFailure(error, loopSerial: loopSerial)
        }
    }

    private func handleCaptureRequestDeferral(
        _ error: CaptureRequestBrokerError,
        loopSerial: Int
    ) {
        guard isCapturing, loopSerial == captureLoopSerial else { return }
        guard case .cooldown(let monotonicDeadline) = error else { return }

        captureScheduleRevision += 1
        captureCooldownDeadline = monotonicDeadline
        nextCaptureAt = nil
    }

    private func handleCaptureFailure(_ error: Error, loopSerial: Int) {
        guard isCapturing, loopSerial == captureLoopSerial else { return }

        let detail = DiagnosticsLogFormat.describe(error)
        let recovery = CaptureFailureRecovery.disposition(
            for: error,
            hasScreenRecordingPermission: Self.hasScreenRecordingPermission()
        )
        if case .backOff(let delay) = recovery {
            consecutiveCaptureFailures = 0
            captureScheduleRevision += 1
            captureCooldownDeadline = Self.monotonicTime() + delay
            nextCaptureAt = nil
            // The shared broker owns the authoritative (possibly escalated)
            // cooldown; this local deadline only parks the loop until its next
            // attempt adopts the broker's real deadline without touching the OS.
            captureLogger.warning(
                "ScreenCaptureKit reported a false permission denial; deferring capture while the shared circuit cools down"
            )
            DiagnosticsLog.shared.log(
                "Capture",
                "ScreenCaptureKit reported a permission denial while preflight remained granted; deferring capture while the shared circuit cools down: \(detail)"
            )
            return
        }

        consecutiveCaptureFailures += 1
        let failureCount = consecutiveCaptureFailures
        captureLogger.error("Screenshot capture failed (\(failureCount, privacy: .public)/\(self.maximumConsecutiveCaptureFailures, privacy: .public)): \(detail, privacy: .public)")
        DiagnosticsLog.shared.log(
            "Capture",
            "Screenshot capture failed (\(failureCount)/\(maximumConsecutiveCaptureFailures)) for display \(targetDisplayID): \(detail); \(CaptureSystemState.summary())"
        )

        guard failureCount >= maximumConsecutiveCaptureFailures else { return }

        DiagnosticsLog.shared.log(
            "Capture",
            "Hard-stopping capture for display \(targetDisplayID) after \(failureCount) consecutive failures"
        )
        _ = stopCaptureLoop()
        delegate?.captureManagerDidStop(self)
    }

    private func captureDimensions(
        for displayDimensions: (width: Int, height: Int)
    ) -> (width: Int, height: Int) {
        ScreenCaptureSizing.outputDimensions(
            displayDimensions: displayDimensions,
            desiredScale: captureScale,
            displayBackingScale: displayBackingScale
        )
    }

    private static func backingScale(for displayID: CGDirectDisplayID) -> CGFloat {
        if let screen = DisplayIdentity.screen(for: displayID) {
            return max(1, screen.backingScaleFactor)
        }
        return 1
    }

    private static func monotonicTime() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

enum ScreenCaptureSizing {
    static func outputDimensions(
        displayDimensions: (width: Int, height: Int),
        desiredScale: Int,
        displayBackingScale: CGFloat
    ) -> (width: Int, height: Int) {
        let scale = min(CGFloat(max(1, desiredScale)), max(1, displayBackingScale))
        return (
            width: max(1, Int((CGFloat(displayDimensions.width) * scale).rounded())),
            height: max(1, Int((CGFloat(displayDimensions.height) * scale).rounded()))
        )
    }
}
