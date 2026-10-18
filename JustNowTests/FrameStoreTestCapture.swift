import CoreGraphics
import Foundation
@testable import JustNow

enum FrameStoreTestCaptureError: Error {
    case encodingFailed
    case notInserted(FrameStoreCaptureMutation)
    case metadataMissing(UUID)
}

extension FrameStore {
    /// Stores a synthetic capture through the production write path,
    /// `recordEncodedCapture(forceNewSpan: true)`, so every call adds its own
    /// frame and span even when the encoded bytes repeat.
    ///
    /// Like real capture, this needs an open capture session: call
    /// `beginCaptureSession(at:)` first. Captures older than the session
    /// start are rejected as stale observations.
    @discardableResult
    func recordTestCapture(
        _ image: CGImage,
        timestamp: Date,
        hash: UInt64,
        displayID: UUID? = nil,
        displayName: String? = nil,
        quality: CGFloat = ImageEncoder.fullImageQuality
    ) throws -> FrameMetadata {
        guard let jpegData = ImageEncoder.jpegData(from: image, quality: quality) else {
            throw FrameStoreTestCaptureError.encodingFailed
        }
        let frame = StoredFrame(
            id: UUID(),
            timestamp: timestamp,
            hash: hash,
            displayID: displayID,
            displayName: displayName
        )
        let result = try recordEncodedCapture(frame: frame, jpegData: jpegData, forceNewSpan: true)
        guard case .inserted(let entry) = result.mutation, entry.frame.id == frame.id else {
            throw FrameStoreTestCaptureError.notInserted(result.mutation)
        }
        guard let metadata = getAllMetadata().first(where: { $0.id == frame.id }) else {
            throw FrameStoreTestCaptureError.metadataMissing(frame.id)
        }
        return metadata
    }
}
