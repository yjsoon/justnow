//
//  FrameBuffer.swift
//  JustNow
//

import CoreVideo
import CoreImage
import AppKit
import Foundation

/// Lightweight frame reference - actual image loaded from disk on demand
struct StoredFrame: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let hash: UInt64
}

@MainActor
class FrameBuffer {
    private var frames: [StoredFrame] = []
    private var lastHash: UInt64?
    // Hamming distance threshold: higher = more frames kept
    // 64 bits total, so 3 means ~5% difference required (very strict)
    // Using 3 to only skip nearly-identical consecutive frames
    private let hashThreshold: Int = 3

    private let frameStore: FrameStore
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let retentionManager = RetentionManager()

    // Thumbnail cache for quick access
    private let thumbnailCache = NSCache<NSUUID, NSImage>()

    init() async throws {
        self.frameStore = try FrameStore()
        thumbnailCache.countLimit = 100

        // Load persisted frames
        await loadPersistedFrames()

        // Cleanup orphaned files
        try await frameStore.cleanupOrphans()
    }

    // MARK: - Capture

    func addFrame(_ pixelBuffer: CVPixelBuffer, timestamp: Date) {
        // Convert to CGImage immediately
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            print("Failed to create CGImage from pixel buffer")
            return
        }

        let hash = PerceptualHash.compute(from: cgImage)

        // Skip if too similar to previous frame (only skip nearly-identical frames)
        if let last = lastHash {
            let distance = PerceptualHash.hammingDistance(hash, last)
            if distance <= hashThreshold {
                // Silently skip - this is expected for static screens
                return
            }
            print("Frame accepted: distance=\(distance) threshold=\(hashThreshold)")
        } else {
            print("First frame captured")
        }

        // Save to disk
        Task {
            do {
                let metadata = try await frameStore.saveFrame(cgImage, timestamp: timestamp, hash: hash)

                let frame = StoredFrame(
                    id: metadata.id,
                    timestamp: metadata.timestamp,
                    hash: metadata.hash
                )

                frames.append(frame)
                lastHash = hash

                await pruneIfNeeded()
            } catch {
                print("Failed to save frame: \(error)")
            }
        }
    }

    // MARK: - Access

    func getFrames() -> [StoredFrame] {
        frames
    }

    func getRecentFrames(within seconds: TimeInterval) -> [StoredFrame] {
        let cutoff = Date().addingTimeInterval(-seconds)
        return frames.filter { $0.timestamp >= cutoff }
    }

    var frameCount: Int {
        frames.count
    }

    /// Load full-resolution image from disk
    func getFullImage(for frame: StoredFrame) async throws -> CGImage {
        try await frameStore.loadFullImage(id: frame.id)
    }

    /// Get thumbnail, with caching
    func getThumbnail(for frame: StoredFrame) async -> NSImage? {
        let key = frame.id as NSUUID

        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }

        guard let cgImage = await frameStore.loadThumbnail(id: frame.id) else {
            return nil
        }

        let nsImage = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        thumbnailCache.setObject(nsImage, forKey: key)
        return nsImage
    }

    // MARK: - Management

    func clear() async throws {
        try await frameStore.clear()
        frames.removeAll()
        lastHash = nil
        thumbnailCache.removeAllObjects()
    }

    func totalStorageSize() async -> Int64 {
        await frameStore.totalStorageSize()
    }

    // MARK: - Private

    private func loadPersistedFrames() async {
        let metadata = await frameStore.getAllMetadata()

        frames = metadata
            .sorted { $0.timestamp < $1.timestamp }
            .map { StoredFrame(id: $0.id, timestamp: $0.timestamp, hash: $0.hash) }

        // Set lastHash from most recent frame
        if let last = frames.last {
            lastHash = last.hash
        }
    }

    private func pruneIfNeeded() async {
        let toPrune = retentionManager.framesToPrune(frames: frames, currentTime: Date())
        guard !toPrune.isEmpty else { return }

        do {
            try await frameStore.pruneFrames(ids: toPrune)
            frames.removeAll { toPrune.contains($0.id) }
            print("Pruned \(toPrune.count) frames, \(frames.count) remaining")
        } catch {
            print("Failed to prune frames: \(error)")
        }
    }
}
