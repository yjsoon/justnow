//
//  FrameBuffer.swift
//  JustNow
//

import CoreVideo
import Foundation

struct StoredFrame: Identifiable {
    let id: UUID
    let timestamp: Date
    let pixelBuffer: CVPixelBuffer
    let hash: UInt64
}

class FrameBuffer {
    private var frames: [StoredFrame] = []
    private var lastHash: UInt64?
    private let hashThreshold: Int = 5 // Hamming distance threshold

    private let lock = NSLock()
    private let retentionManager = RetentionManager()

    /// Maximum number of frames to keep in memory
    var maxFrames: Int = 600 // ~10 minutes at 1fps

    func addFrame(_ pixelBuffer: CVPixelBuffer, timestamp: Date) {
        let hash = PerceptualHash.compute(from: pixelBuffer)

        // Skip if too similar to previous frame
        if let last = lastHash, PerceptualHash.hammingDistance(hash, last) <= hashThreshold {
            return
        }

        // CVPixelBuffer is automatically memory managed in Swift - no manual retain needed

        let frame = StoredFrame(
            id: UUID(),
            timestamp: timestamp,
            pixelBuffer: pixelBuffer,
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
        // First apply retention policy
        retentionManager.pruneFrames(frames: &frames, currentTime: Date())

        // Then enforce max count
        while frames.count > maxFrames {
            _ = frames.removeFirst()
            // CVPixelBuffer is automatically released when StoredFrame is deallocated
        }
    }

    func clear() {
        lock.lock()
        // CVPixelBuffers are automatically released when frames array is cleared
        frames.removeAll()
        lastHash = nil
        lock.unlock()
    }
}
