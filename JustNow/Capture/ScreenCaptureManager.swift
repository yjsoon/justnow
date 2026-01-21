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
        cfg.width = display.width * 2  // Retina
        cfg.height = display.height * 2
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

    /// Capture a single frame immediately and return it (for overlay open).
    func captureNow() async -> CGImage? {
        guard let filter, let config else { return nil }
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    // MARK: - Private

    private func startTimer() {
        captureTimer?.invalidate()
        captureTimer = Timer.scheduledTimer(withTimeInterval: captureInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.captureOneFrame()
            }
        }
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
}
