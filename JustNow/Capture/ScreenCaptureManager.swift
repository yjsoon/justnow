//
//  ScreenCaptureManager.swift
//  JustNow
//

import ScreenCaptureKit
import AppKit

enum CaptureError: Error {
    case permissionDenied
    case noDisplay
}

private enum CaptureTurnWaitResult {
    case acquired
    case cancelled
}

@MainActor
protocol ScreenCaptureDelegate: AnyObject {
    func captureManager(_ manager: ScreenCaptureManager, didCaptureFrame image: CGImage, at timestamp: Date)
    func captureManagerDidStop(_ manager: ScreenCaptureManager)
}

extension ScreenCaptureDelegate {
    func captureManagerDidStop(_ manager: ScreenCaptureManager) {}
}

/// Uses SCScreenshotManager for one-shot captures instead of SCStream.
/// This avoids the persistent purple "sharing" indicator in the menu bar.
@MainActor
class ScreenCaptureManager: NSObject {
    private let maximumConsecutiveCaptureFailures = 3

    private var filter: SCContentFilter?
    private var config: SCStreamConfiguration?
    private var displayDimensions: (width: Int, height: Int)?
    private var captureScale: Int = 2

    weak var delegate: ScreenCaptureDelegate?
    private(set) var isCapturing = false
    private(set) var captureInterval: TimeInterval = 1.0
    let targetDisplayID: CGDirectDisplayID

    init(targetDisplayID: CGDirectDisplayID) {
        self.targetDisplayID = targetDisplayID
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
    /// Global gate so periodic capture and overlay refreshes never issue overlapping screenshot requests.
    private var isCaptureRequestInFlight = false
    private var captureRequestWaiters: [(id: UUID, continuation: CheckedContinuation<CaptureTurnWaitResult, Never>)] = []
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
            throw CaptureError.permissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == targetDisplayID })
            ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let dimensions = (width: display.width, height: display.height)
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let cfg = SCStreamConfiguration()
        applyCaptureScale(to: cfg, dimensions: dimensions)
        cfg.showsCursor = true
        cfg.capturesAudio = false
        try Task.checkCancellation()

        self.filter = filter
        displayDimensions = dimensions
        config = cfg

        consecutiveCaptureFailures = 0
        isCapturing = true
        captureScheduleRevision += 1
        nextCaptureAt = Date()
        scheduleCaptureLoop()

        print("Capture started successfully (one-shot mode)")
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
        cancelQueuedCaptureRequests()
        wakeCaptureLoop()
        if wasCapturing {
            print("Capture stopped")
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
        return try? await captureImageSerially(expectedLoopSerial: requestLoopSerial)
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

    private func acquireCaptureTurn() async throws {
        if !isCaptureRequestInFlight {
            isCaptureRequestInFlight = true
            return
        }

        let waiterID = UUID()
        let result = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                captureRequestWaiters.append((id: waiterID, continuation: continuation))
                if Task.isCancelled {
                    cancelCaptureRequestWaiter(id: waiterID)
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelCaptureRequestWaiter(id: waiterID)
            }
        })

        if case .cancelled = result {
            throw CancellationError()
        }
    }

    private func cancelCaptureRequestWaiter(id: UUID) {
        guard let index = captureRequestWaiters.firstIndex(where: { $0.id == id }) else { return }
        let continuation = captureRequestWaiters.remove(at: index).continuation
        continuation.resume(returning: .cancelled)
    }

    private func cancelQueuedCaptureRequests() {
        let waiters = captureRequestWaiters
        captureRequestWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(returning: .cancelled)
        }
    }

    private func releaseCaptureTurn() {
        guard !captureRequestWaiters.isEmpty else {
            isCaptureRequestInFlight = false
            return
        }

        let continuation = captureRequestWaiters.removeFirst().continuation
        continuation.resume(returning: .acquired)
    }

    private func captureImageSerially(expectedLoopSerial: Int? = nil) async throws -> CGImage {
        try await acquireCaptureTurn()
        defer { releaseCaptureTurn() }

        try Task.checkCancellation()
        guard let filter, let config else {
            throw CancellationError()
        }
        if let expectedLoopSerial {
            guard isCapturing, captureLoopSerial == expectedLoopSerial else {
                throw CancellationError()
            }
        }

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
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
            let image = try await captureImageSerially(expectedLoopSerial: loopSerial)
            guard isCapturing, !Task.isCancelled, loopSerial == captureLoopSerial else { return }
            consecutiveCaptureFailures = 0
            let timestamp = Date()
            delegate?.captureManager(self, didCaptureFrame: image, at: timestamp)
        } catch is CancellationError {
            // Expected when stopping capture.
        } catch {
            handleCaptureFailure(error, loopSerial: loopSerial)
        }
    }

    private func handleCaptureFailure(_ error: Error, loopSerial: Int) {
        guard isCapturing, loopSerial == captureLoopSerial else { return }

        consecutiveCaptureFailures += 1
        let failureCount = consecutiveCaptureFailures
        print("Screenshot capture failed (\(failureCount)/\(maximumConsecutiveCaptureFailures)): \(error)")

        guard failureCount >= maximumConsecutiveCaptureFailures else { return }

        _ = stopCaptureLoop()
        delegate?.captureManagerDidStop(self)
    }

    private func applyCaptureScale(to config: SCStreamConfiguration) {
        guard let displayDimensions else { return }
        applyCaptureScale(to: config, dimensions: displayDimensions)
    }

    private func applyCaptureScale(to config: SCStreamConfiguration, dimensions: (width: Int, height: Int)) {
        config.width = dimensions.width * captureScale
        config.height = dimensions.height * captureScale
    }
}
