//
//  FrameBuffer.swift
//  JustNow
//

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
    private let frameStore: FrameStore
    private let retentionManager = RetentionManager()
    private var blackFrameFilterUntil: Date?

    // Pause pruning while overlay is open to prevent "Frame removed" issues
    var isPruningPaused: Bool = false

    // Thumbnail cache for quick access
    private let thumbnailCache = NSCache<NSUUID, NSImage>()

    // OCR text cache for faster subsequent searches
    let textCache = TextCache()

    init() async throws {
        self.frameStore = try FrameStore()
        thumbnailCache.countLimit = 100

        // Load persisted frames
        await loadPersistedFrames()

        // Cleanup orphaned files
        try await frameStore.cleanupOrphans()

        // Prune stale text cache entries
        let validIDs = Set(frames.map { $0.id })
        await textCache.prune(keepingFrameIDs: validIDs)
    }

    // MARK: - Capture

    func addFrame(_ cgImage: CGImage, timestamp: Date) {
        // Skip black frames only during sleep/wake transitions.
        if shouldCheckBlackFrame(at: timestamp) && isBlackFrame(cgImage) {
            print("Skipping black frame")
            return
        }

        // Save to disk (keep all frames, filter duplicates at display time)
        // Hash computation runs concurrently on background thread
        Task {
            do {
                // Compute perceptual hash on background thread (via @concurrent)
                let hash = await PerceptualHash.compute(from: cgImage)
                let metadata = try await frameStore.saveFrame(cgImage, timestamp: timestamp, hash: hash)

                let frame = StoredFrame(
                    id: metadata.id,
                    timestamp: metadata.timestamp,
                    hash: metadata.hash
                )

                frames.append(frame)

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

    /// Get frames with near-duplicates removed for smoother browsing.
    /// Uses perceptual hash comparison - frames with hamming distance <= threshold are duplicates.
    func getFilteredFrames(hashThreshold: Int = 3) -> [StoredFrame] {
        guard !frames.isEmpty else { return [] }

        var filtered: [StoredFrame] = []
        var lastHash: UInt64?

        for frame in frames {
            // Legacy frames without hash (hash=0) always kept, reset comparison chain
            guard frame.hash != 0 else {
                filtered.append(frame)
                lastHash = nil
                continue
            }

            // Keep if different enough from last kept frame
            let isDifferent = lastHash.map { PerceptualHash.hammingDistance(frame.hash, $0) > hashThreshold } ?? true
            if isDifferent {
                filtered.append(frame)
                lastHash = frame.hash
            }
        }

        return filtered
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
    }

    func enableBlackFrameFilter(for seconds: TimeInterval) {
        blackFrameFilterUntil = Date().addingTimeInterval(seconds)
    }

    private func pruneIfNeeded() async {
        guard !isPruningPaused else { return }

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

    /// Detect true "screen off" frames vs dark content.
    /// Screen-off frames are uniformly black (all ~0), dark content has variation.
    private func isBlackFrame(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height

        guard width > 0 && height > 0,
              let dataProvider = image.dataProvider,
              let data = dataProvider.data,
              let bytes = CFDataGetBytePtr(data) else {
            return false
        }

        let bytesPerPixel = image.bitsPerPixel / 8
        let bytesPerRow = image.bytesPerRow

        guard bytesPerPixel >= 3 else { return false }
        let gridSize = 8
        var maxY: UInt8 = 0
        var minY: UInt8 = 255
        var darkCount = 0
        var sampleCount = 0

        for gy in 0..<gridSize {
            let y = (height * (2 * gy + 1)) / (2 * gridSize)
            for gx in 0..<gridSize {
                let x = (width * (2 * gx + 1)) / (2 * gridSize)
                let offset = y * bytesPerRow + x * bytesPerPixel
                let r = bytes[offset]
                let g = bytes[offset + 1]
                let b = bytes[offset + 2]

                // Integer luma approximation: 0.2126r + 0.7152g + 0.0722b
                let luma = UInt8((UInt16(r) * 54 + UInt16(g) * 183 + UInt16(b) * 19) >> 8)

                maxY = max(maxY, luma)
                minY = min(minY, luma)
                if luma < 5 { darkCount += 1 }
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else { return false }

        let darkRatio = Double(darkCount) / Double(sampleCount)

        // True black frame: mostly dark and uniform
        // - Max luma < 6 (true black, not just dark)
        // - Luma range < 3 (uniform, no structure)
        // - At least 95% of samples are dark
        let isVeryDark = maxY < 6
        let isUniform = (maxY - minY) < 3
        let isMostlyDark = darkRatio >= 0.95

        return isVeryDark && isUniform && isMostlyDark
    }

    private func shouldCheckBlackFrame(at timestamp: Date) -> Bool {
        guard let until = blackFrameFilterUntil else { return false }
        return timestamp <= until
    }
}
