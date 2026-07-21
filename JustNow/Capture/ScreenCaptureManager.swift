//
//  ScreenCaptureManager.swift
//  JustNow
//

import ScreenCaptureKit
import AppKit
import CoreVideo
import os.log

private let captureLogger = Logger(subsystem: "sg.tk.JustNow", category: "Capture")

enum CaptureError: Error {
    case permissionDenied
    case noDisplay
}

enum CaptureFailureRecovery: Equatable {
    case countTowardsStop
    case backOff(TimeInterval)

    nonisolated static let falsePermissionDenialDelay: TimeInterval = 30

    nonisolated static func disposition(
        for error: Error,
        hasScreenRecordingPermission: Bool
    ) -> CaptureFailureRecovery {
        let nsError = error as NSError
        guard hasScreenRecordingPermission,
              nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
              nsError.code == -3801 else {
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
    private var config: SCStreamConfiguration?
    private var displayDimensions: (width: Int, height: Int)?
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

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == targetDisplayID }) else {
            throw CaptureError.noDisplay
        }

        let dimensions = (width: display.width, height: display.height)
        displayBackingScale = Self.backingScale(for: targetDisplayID)
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let cfg = SCStreamConfiguration()
        applyCaptureScale(to: cfg, dimensions: dimensions)
        cfg.showsCursor = true
        cfg.capturesAudio = false
        // Pin the surface format so SCK doesn't pick a wider, more expensive
        // default. BGRA + sRGB matches the JPEG encode path and avoids hidden
        // colour-space conversion on every capture.
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        try Task.checkCancellation()

        self.filter = filter
        displayDimensions = dimensions
        config = cfg

        consecutiveCaptureFailures = 0
        isCapturing = true
        captureScheduleRevision += 1
        nextCaptureAt = Date()
        scheduleCaptureLoop()

        captureLogger.info("Capture started successfully (one-shot mode) for display \(self.targetDisplayID, privacy: .public)")
    }

    func stopCapture() async {
        let previousLoop = stopCaptureLoop()
        await previousLoop?.value
    }

    private func stopCaptureLoop() -> Task<Void, Never>? {
        let previousLoop = captureLoopTask
        let wasCapturing = isCapturing || previousLoop != nil
        captureLoopSerial += 1
        captureScheduleRevision += 1
        isCapturing = false
        consecutiveCaptureFailures = 0
        nextCaptureAt = nil
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
        guard let config else { return }
        applyCaptureScale(to: config)
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
            guard let filter = self.filter, let config = self.config else {
                throw CancellationError()
            }
            if let expectedLoopSerial {
                guard self.isCapturing, self.captureLoopSerial == expectedLoopSerial else {
                    throw CancellationError()
                }
            }

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
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
        guard case .cooldown(let deadline) = error else { return }

        captureScheduleRevision += 1
        nextCaptureAt = deadline
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
            nextCaptureAt = Date().addingTimeInterval(delay)
            captureLogger.warning(
                "ScreenCaptureKit reported a false permission denial; backing off for \(delay, privacy: .public) seconds"
            )
            DiagnosticsLog.shared.log(
                "Capture",
                "ScreenCaptureKit reported a permission denial while preflight remained granted; backing off for \(delay) seconds: \(detail)"
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

    private func applyCaptureScale(to config: SCStreamConfiguration) {
        guard let displayDimensions else { return }
        applyCaptureScale(to: config, dimensions: displayDimensions)
    }

    private func applyCaptureScale(to config: SCStreamConfiguration, dimensions: (width: Int, height: Int)) {
        let output = ScreenCaptureSizing.outputDimensions(
            displayDimensions: dimensions,
            desiredScale: captureScale,
            displayBackingScale: displayBackingScale
        )
        config.width = output.width
        config.height = output.height
    }

    private static func backingScale(for displayID: CGDirectDisplayID) -> CGFloat {
        if let screen = DisplayIdentity.screen(for: displayID) {
            return max(1, screen.backingScaleFactor)
        }
        return 1
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
