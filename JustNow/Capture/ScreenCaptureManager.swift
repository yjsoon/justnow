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
    private var captureTimer: Timer?
    private var filter: SCContentFilter?
    private var config: SCStreamConfiguration?
    private var displayDimensions: (width: Int, height: Int)?
    private var captureScale: Int = 2

    weak var delegate: ScreenCaptureDelegate?
    private(set) var isCapturing = false
    private(set) var captureInterval: TimeInterval = 1.0

    func startCapture() async throws {
        // Stop any existing capture
        stopCaptureSync()

        // Request permission
        guard CGRequestScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let cfg = SCStreamConfiguration()
        displayDimensions = (width: display.width, height: display.height)
        applyCaptureScale(to: cfg)
        cfg.showsCursor = true
        cfg.capturesAudio = false
        config = cfg

        // Capture immediately, then start timer
        captureOneFrame()
        startTimer()

        isCapturing = true
        print("Capture started successfully (one-shot mode)")
    }

    func stopCapture() async {
        stopCaptureSync()
    }

    private func stopCaptureSync() {
        captureTimer?.invalidate()
        captureTimer = nil
        isCapturing = false
        print("Capture stopped")
    }

    func updateCaptureInterval(_ interval: TimeInterval) {
        captureInterval = interval
        guard isCapturing else { return }
        // Restart timer with new interval
        startTimer()
    }

    func updateCaptureScale(_ scale: Int) {
        captureScale = max(1, scale)
        guard let config else { return }
        applyCaptureScale(to: config)
    }

    /// Capture a single frame immediately and return it (for overlay open).
    func captureNow() async -> CGImage? {
        guard let filter, let config else { return nil }
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    // MARK: - Private

    private func startTimer() {
        captureTimer?.invalidate()
        captureTimer = Timer.scheduledTimer(withTimeInterval: captureInterval, repeats: true) { [weak self] _ in
            self?.captureOneFrame()
        }
        captureTimer?.tolerance = min(captureInterval * 0.2, 1.0)
    }

    private func captureOneFrame() {
        guard let filter, let config else { return }

        Task {
            do {
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: config
                )
                let timestamp = Date()
                await MainActor.run {
                    self.delegate?.captureManager(self, didCaptureFrame: image, at: timestamp)
                }
            } catch {
                print("Screenshot capture failed: \(error)")
            }
        }
    }

    private func applyCaptureScale(to config: SCStreamConfiguration) {
        guard let displayDimensions else { return }
        config.width = displayDimensions.width * captureScale
        config.height = displayDimensions.height * captureScale
    }
}
