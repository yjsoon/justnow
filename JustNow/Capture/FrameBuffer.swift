//
//  FrameBuffer.swift
//  JustNow
//

import CoreVideo
import CoreImage
import AppKit
import Foundation

struct StoredFrame: Identifiable {
    let id: UUID
    let timestamp: Date
    let image: CGImage  // Store CGImage instead of CVPixelBuffer (which gets recycled)
    let hash: UInt64
}

class FrameBuffer {
    private var frames: [StoredFrame] = []
    private var lastHash: UInt64?
    private let hashThreshold: Int = 8 // Hamming distance threshold (increased for less aggressive filtering)

    private let lock = NSLock()
    private let retentionManager = RetentionManager()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Maximum number of frames to keep in memory
    var maxFrames: Int = 600 // ~10 minutes at 1fps

    func addFrame(_ pixelBuffer: CVPixelBuffer, timestamp: Date) {
        // Convert to CGImage immediately since CVPixelBuffer will be recycled
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return
        }

        let hash = PerceptualHash.compute(from: cgImage)

        // Skip if too similar to previous frame
        if let last = lastHash {
            let distance = PerceptualHash.hammingDistance(hash, last)
            if distance <= hashThreshold {
                return
            }
        }

        let frame = StoredFrame(
            id: UUID(),
            timestamp: timestamp,
            image: cgImage,
            hash: hash
        )

        lock.lock()
        frames.append(frame)
        lastHash = hash

        // Prune old frames
        pruneFrames()
        lock.unlock()
    }

    func getFrames() -> [StoredFrame] {
        lock.lock()
        let result = frames
        lock.unlock()
        return result
    }

    func getRecentFrames(within seconds: TimeInterval) -> [StoredFrame] {
        let cutoff = Date().addingTimeInterval(-seconds)
        lock.lock()
        let result = frames.filter { $0.timestamp >= cutoff }
        lock.unlock()
        return result
    }

    var frameCount: Int {
        lock.lock()
        let count = frames.count
        lock.unlock()
        return count
    }

    private func pruneFrames() {
        // Only enforce max count - retention manager was too aggressive
        // The maxFrames limit is sufficient for memory management
        while frames.count > maxFrames {
            _ = frames.removeFirst()
        }
    }

    func clear() {
        lock.lock()
        frames.removeAll()
        lastHash = nil
        lock.unlock()
    }
}
