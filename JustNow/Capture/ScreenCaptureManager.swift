//
//  ScreenCaptureManager.swift
//  JustNow
//

import ScreenCaptureKit
import CoreMedia
import CoreVideo

enum CaptureError: Error {
    case permissionDenied
    case noDisplay
    case streamConfigurationFailed
}

protocol ScreenCaptureDelegate: AnyObject {
    func captureManager(_ manager: ScreenCaptureManager, didCaptureFrame pixelBuffer: CVPixelBuffer, at timestamp: Date)
}

@MainActor
class ScreenCaptureManager: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private let captureQueue = DispatchQueue(label: "sg.tk.justnow.capture", qos: .utility)

    weak var delegate: ScreenCaptureDelegate?
    private(set) var isCapturing = false

    private var currentConfig: SCStreamConfiguration?
    private var currentFilter: SCContentFilter?

    func startCapture() async throws {
        guard !isCapturing else { return }

        // Request permission
        guard CGRequestScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        currentFilter = filter

        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps
        config.width = display.width * 2 // Retina
        config.height = display.height * 2
        config.queueDepth = 3
        config.showsCursor = true
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        currentConfig = config

        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream?.startCapture()

        isCapturing = true
    }

    func stopCapture() async {
        guard isCapturing else { return }

        try? await stream?.stopCapture()
        stream = nil
        isCapturing = false
    }

    func updateCaptureInterval(_ interval: CMTime) async throws {
        guard let config = currentConfig else { return }
        config.minimumFrameInterval = interval
        try await stream?.updateConfiguration(config)
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let timestamp = Date()

        Task { @MainActor in
            self.delegate?.captureManager(self, didCaptureFrame: pixelBuffer, at: timestamp)
        }
    }
}
