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

struct DuplicateFramePolicy: Sendable, Equatable {
    let hashThreshold: Int
    let minimumSpacing: TimeInterval

    static let standard = DuplicateFramePolicy.exact(atMostEvery: 0.5)
    static let lowPower = DuplicateFramePolicy(hashThreshold: 1, minimumSpacing: 5)

    static func exact(atMostEvery interval: TimeInterval) -> DuplicateFramePolicy {
        let clampedInterval = max(interval, 0.5)
        return DuplicateFramePolicy(hashThreshold: 0, minimumSpacing: clampedInterval)
    }
}

struct OCRIndexingPolicy: Sendable, Equatable {
    let isEnabled: Bool
    let minimumInterval: TimeInterval
    let maxQueueDepth: Int
    let maxFrameAge: TimeInterval

    static let disabled = OCRIndexingPolicy(
        isEnabled: false,
        minimumInterval: 0,
        maxQueueDepth: 0,
        maxFrameAge: 0
    )
}

private enum SyncIngestResult {
    case completed
    case retryAfterClear
}

private enum ClearWaitResult {
    case ready
    case cancelled
}

private struct PendingIngest {
    let cgImage: CGImage
    let timestamp: Date
    let generation: Int
    let syncContinuation: CheckedContinuation<SyncIngestResult, Never>?
}

@MainActor
class FrameBuffer {
    private var frames: [StoredFrame] = []
    private let frameStore: FrameStore
    private let retentionManager: RetentionManager
    private var blackFrameFilterUntil: Date?
    private var saveOptions: FrameSaveOptions = .standard
    private var duplicatePolicy: DuplicateFramePolicy = .standard
    private var lastPruneCheck: Date = .distantPast
    private let pruneInterval: TimeInterval = 30
    private var ocrIndexingPolicy: OCRIndexingPolicy = .disabled
    private var ocrIndexQueue: [StoredFrame] = []
    private var queuedOCRFrameIDs: Set<UUID> = []
    private var ocrPruningFrameIDs: Set<UUID> = []
    private var ocrIndexingTask: Task<Void, Never>?
    /// Bounded backlog of captures waiting to hash and persist. Sync captures discard older async backlog rather than reordering processing, so dedupe stays chronological.
    private var ingestQueue: [PendingIngest] = []
    private var ingestProcessorTask: Task<Void, Never>?
    /// Incremented when starting each ingest drain and when clearing the buffer so a superseded drain cannot clear `ingestProcessorTask` or restart incorrectly.
    private var ingestProcessorSerial = 0
    private let maxIngestBacklog = 6
    /// Bumped in `clear()` so in-flight ingest work can drop results and avoid racing a reset buffer.
    private var ingestGeneration = 0
    /// While true, new captures are not queued and disk reset is in progress — avoids races with `frames.removeAll()` and ingest teardown.
    private var isBufferClearing = false
    private var activeClearOperationCount = 0
    private var clearWaiters: [(id: UUID, continuation: CheckedContinuation<ClearWaitResult, Never>)] = []
    private let searchTelemetry = SearchTelemetry.shared

    // Pause pruning while overlay is open to prevent "Frame removed" issues
    var isPruningPaused: Bool = false

    // Thumbnail cache for quick access
    private let thumbnailCache = NSCache<NSUUID, NSImage>()

    // OCR text cache for faster subsequent searches
    let textCache = TextCache()

    init(retentionPolicy: RetentionPolicy) async throws {
        self.frameStore = try FrameStore()
        self.retentionManager = RetentionManager(policy: retentionPolicy)
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

        enqueueIngest(cgImage: cgImage, timestamp: timestamp, syncContinuation: nil, prioritiseSync: false)
    }

    /// Add a frame synchronously (awaits save completion). Used when opening overlay.
    func addFrameSync(_ cgImage: CGImage, timestamp: Date) async {
        if shouldCheckBlackFrame(at: timestamp) && isBlackFrame(cgImage) {
            return
        }

        while !Task.isCancelled {
            do {
                try await waitUntilNotClearing()
            } catch is CancellationError {
                return
            } catch {
                return
            }

            guard !Task.isCancelled else { return }

            let result = await withCheckedContinuation { continuation in
                enqueueIngest(
                    cgImage: cgImage,
                    timestamp: timestamp,
                    syncContinuation: continuation,
                    prioritiseSync: true
                )
            }

            guard !Task.isCancelled else { return }

            switch result {
            case .completed:
                return
            case .retryAfterClear:
                continue
            }
        }
    }

    // MARK: - Access

    func getFrames() -> [StoredFrame] {
        frames
    }

    func containsFrame(id: UUID) -> Bool {
        frames.contains { $0.id == id }
    }

    func cacheOCRTextIfCurrent(_ text: String, for frame: StoredFrame) async -> Bool {
        guard shouldContinueOCR(for: frame) else { return false }
        await textCache.setText(text, for: frame.id, timestamp: frame.timestamp)

        guard shouldContinueOCR(for: frame) else {
            await textCache.removeText(for: frame.id)
            return false
        }

        return true
    }

    /// Get frames with near-duplicates removed for smoother browsing.
    /// The newest window keeps all stored frames so keyboard navigation tracks recent capture cadence.
    func getFilteredFrames(
        hashThreshold: Int = 3,
        recentWindow: TimeInterval = 300,
        maximumAge: TimeInterval? = nil
    ) -> [StoredFrame] {
        guard !frames.isEmpty else { return [] }

        let now = Date()
        let candidateFrames: [StoredFrame]
        if let maximumAge {
            let cutoff = now.addingTimeInterval(-maximumAge)
            candidateFrames = frames.filter { $0.timestamp >= cutoff }
        } else {
            candidateFrames = frames
        }

        var filtered: [StoredFrame] = []
        var lastHash: UInt64?

        for frame in candidateFrames {
            let age = now.timeIntervalSince(frame.timestamp)

            // Keep every stored frame in the recent window.
            if age <= recentWindow {
                filtered.append(frame)
                lastHash = frame.hash
                continue
            }

            // Legacy frames without hash (hash=0) always kept, reset comparison chain
            guard frame.hash != 0 else {
                filtered.append(frame)
                lastHash = nil
                continue
            }

            // Use stronger dedupe only once frames age out of the recent navigation window.
            let threshold = hashThreshold

            // Keep if different enough from last kept frame
            let isDifferent = lastHash.map { PerceptualHash.hammingDistance(frame.hash, $0) > threshold } ?? true
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
        activeClearOperationCount += 1
        isBufferClearing = true
        defer {
            activeClearOperationCount -= 1
            if activeClearOperationCount == 0 {
                isBufferClearing = false
                let waiters = clearWaiters
                clearWaiters.removeAll()
                for resume in waiters {
                    resume.continuation.resume(returning: .ready)
                }
            }
        }

        ingestGeneration += 1
        ingestProcessorSerial += 1
        ingestProcessorTask?.cancel()
        ingestProcessorTask = nil
        let stuckSync = ingestQueue.compactMap { $0.syncContinuation }
        ingestQueue.removeAll()
        for resume in stuckSync {
            resume.resume(returning: .retryAfterClear)
        }
        cancelBackgroundOCRIndexing(clearQueue: true)
        try await frameStore.clear()
        frames.removeAll()
        thumbnailCache.removeAllObjects()
        await textCache.clear()
    }

    func totalStorageSize() async -> Int64 {
        await frameStore.totalStorageSize()
    }

    func updateSaveOptions(_ options: FrameSaveOptions, duplicatePolicy: DuplicateFramePolicy) {
        saveOptions = options
        self.duplicatePolicy = duplicatePolicy
    }

    func updateOCRIndexingPolicy(_ policy: OCRIndexingPolicy) {
        guard policy != ocrIndexingPolicy else { return }
        ocrIndexingPolicy = policy

        guard policy.isEnabled else {
            cancelBackgroundOCRIndexing(clearQueue: true)
            return
        }

        enqueueRecentFramesForBackgroundOCR(maxAge: policy.maxFrameAge)
        startBackgroundOCRIndexingIfNeeded()
    }

    func updateRetentionPolicy(_ policy: RetentionPolicy) async {
        retentionManager.updatePolicy(policy)
        await prune(force: true)
    }

    func flushCaches() async {
        while let ingestProcessorTask {
            await ingestProcessorTask.value
        }
        await frameStore.flushManifest()
        await textCache.save()
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

    private func waitUntilNotClearing() async throws {
        guard isBufferClearing else { return }

        let waiterID = UUID()
        let result = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                clearWaiters.append((id: waiterID, continuation: continuation))
                if Task.isCancelled {
                    cancelClearWaiter(id: waiterID)
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelClearWaiter(id: waiterID)
            }
        })

        if case .cancelled = result {
            throw CancellationError()
        }
    }

    private func cancelClearWaiter(id: UUID) {
        guard let index = clearWaiters.firstIndex(where: { $0.id == id }) else { return }
        let continuation = clearWaiters.remove(at: index).continuation
        continuation.resume(returning: .cancelled)
    }

    private func enqueueIngest(
        cgImage: CGImage,
        timestamp: Date,
        syncContinuation: CheckedContinuation<SyncIngestResult, Never>?,
        prioritiseSync: Bool
    ) {
        if isBufferClearing {
            syncContinuation?.resume(returning: .retryAfterClear)
            return
        }

        let pending = PendingIngest(
            cgImage: cgImage,
            timestamp: timestamp,
            generation: ingestGeneration,
            syncContinuation: syncContinuation
        )

        if prioritiseSync {
            ingestQueue.removeAll { $0.syncContinuation == nil }
        }

        ingestQueue.append(pending)
        trimIngestQueueIfNeeded()
        startIngestProcessorIfNeeded()
    }

    /// Drops oldest async-only pending captures until at most `maxIngestBacklog` remain.
    private func trimIngestQueueIfNeeded() {
        while ingestQueue.count > maxIngestBacklog,
              let dropIndex = ingestQueue.firstIndex(where: { $0.syncContinuation == nil }) {
            ingestQueue.remove(at: dropIndex)
        }
    }

    private func startIngestProcessorIfNeeded() {
        guard ingestProcessorTask == nil, !ingestQueue.isEmpty else { return }
        ingestProcessorSerial += 1
        let processorSerial = ingestProcessorSerial
        ingestProcessorTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.drainIngestQueueOnMainActor(processorSerial: processorSerial)
        }
    }

    private func drainIngestQueueOnMainActor(processorSerial: Int) async {
        while !Task.isCancelled {
            guard let work = dequeueIngestWork() else { break }
            let hash = await PerceptualHash.compute(from: work.cgImage)
            await processHashedIngest(work, hash: hash)
        }
        guard processorSerial == ingestProcessorSerial else { return }
        ingestProcessorTask = nil
        if !ingestQueue.isEmpty {
            startIngestProcessorIfNeeded()
        }
    }

    private func dequeueIngestWork() -> PendingIngest? {
        guard !ingestQueue.isEmpty else { return nil }
        return ingestQueue.removeFirst()
    }

    private func processHashedIngest(_ work: PendingIngest, hash: UInt64) async {
        let result: SyncIngestResult
        if !matchesIngestGeneration(work.generation) {
            result = .retryAfterClear
        } else {
            result = await persistIngestedFrame(
                cgImage: work.cgImage,
                timestamp: work.timestamp,
                hash: hash,
                ingestGeneration: work.generation
            )
        }
        work.syncContinuation?.resume(returning: result)
    }

    private func matchesIngestGeneration(_ generation: Int) -> Bool {
        generation == ingestGeneration
    }

    private func persistIngestedFrame(
        cgImage: CGImage,
        timestamp: Date,
        hash: UInt64,
        ingestGeneration generation: Int
    ) async -> SyncIngestResult {
        guard generation == ingestGeneration else { return .retryAfterClear }
        guard shouldStoreFrame(hash: hash, timestamp: timestamp) else { return .completed }
        do {
            let metadata = try await frameStore.saveFrame(
                cgImage,
                timestamp: timestamp,
                hash: hash,
                options: saveOptions
            )
            guard generation == ingestGeneration else {
                try? await frameStore.pruneFrames(ids: [metadata.id])
                return .retryAfterClear
            }
            let frame = StoredFrame(
                id: metadata.id,
                timestamp: metadata.timestamp,
                hash: metadata.hash
            )
            recordStoredFrame(frame)
            enqueueFrameForBackgroundOCR(frame)
            await pruneIfNeeded()
            return .completed
        } catch is CancellationError {
            return .retryAfterClear
        } catch {
            print("Failed to save frame: \(error)")
            return .completed
        }
    }

    private func pruneIfNeeded() async {
        await prune(force: false)
    }

    private func prune(force: Bool) async {
        guard !isPruningPaused else { return }

        let now = Date()
        if !force {
            guard now.timeIntervalSince(lastPruneCheck) >= pruneInterval else { return }
        }
        lastPruneCheck = now

        let toPrune = retentionManager.framesToPrune(frames: frames, currentTime: now)
        guard !toPrune.isEmpty else { return }

        ocrPruningFrameIDs.formUnion(toPrune)
        defer {
            ocrPruningFrameIDs.subtract(toPrune)
        }

        do {
            try await frameStore.pruneFrames(ids: toPrune)
            frames.removeAll { toPrune.contains($0.id) }
            removeQueuedOCRFrames(ids: toPrune)
            let validIDs = Set(frames.map { $0.id })
            await textCache.prune(keepingFrameIDs: validIDs)
            print("Pruned \(toPrune.count) frames, \(frames.count) remaining")
        } catch {
            print("Failed to prune frames: \(error)")
        }
    }

    private func shouldStoreFrame(hash: UInt64, timestamp: Date) -> Bool {
        let insertionIndex = frameInsertionIndex(for: timestamp)
        guard insertionIndex > 0 else {
            return true
        }

        let previousFrame = frames[insertionIndex - 1]
        guard previousFrame.hash != 0 else { return true }

        let timeSinceLast = timestamp.timeIntervalSince(previousFrame.timestamp)
        guard timeSinceLast < duplicatePolicy.minimumSpacing else { return true }

        let distance = PerceptualHash.hammingDistance(hash, previousFrame.hash)
        return distance > duplicatePolicy.hashThreshold
    }

    private func frameInsertionIndex(for timestamp: Date) -> Int {
        var low = 0
        var high = frames.count

        while low < high {
            let mid = (low + high) / 2
            if frames[mid].timestamp <= timestamp {
                low = mid + 1
            } else {
                high = mid
            }
        }

        return low
    }

    private func recordStoredFrame(_ frame: StoredFrame) {
        frames.insert(frame, at: frameInsertionIndex(for: frame.timestamp))
    }

    private func enqueueFrameForBackgroundOCR(_ frame: StoredFrame) {
        guard ocrIndexingPolicy.isEnabled else { return }
        guard !queuedOCRFrameIDs.contains(frame.id) else { return }

        ocrIndexQueue.append(frame)
        queuedOCRFrameIDs.insert(frame.id)
        trimOCRIndexQueueIfNeeded()
        startBackgroundOCRIndexingIfNeeded()
    }

    private func enqueueRecentFramesForBackgroundOCR(maxAge: TimeInterval) {
        guard maxAge > 0 else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        let candidates = frames.filter { $0.timestamp >= cutoff }

        for frame in candidates {
            guard !queuedOCRFrameIDs.contains(frame.id) else { continue }
            ocrIndexQueue.append(frame)
            queuedOCRFrameIDs.insert(frame.id)
        }

        trimOCRIndexQueueIfNeeded()
    }

    private func trimOCRIndexQueueIfNeeded() {
        let maxDepth = max(ocrIndexingPolicy.maxQueueDepth, 0)

        if maxDepth == 0 {
            ocrIndexQueue.removeAll()
            queuedOCRFrameIDs.removeAll()
            return
        }

        while ocrIndexQueue.count > maxDepth {
            let dropped = ocrIndexQueue.removeFirst()
            queuedOCRFrameIDs.remove(dropped.id)
        }

        recordQueueDepthTelemetry()
    }

    private func startBackgroundOCRIndexingIfNeeded() {
        guard ocrIndexingPolicy.isEnabled else { return }
        guard ocrIndexingTask == nil else { return }

        ocrIndexingTask = Task(priority: .utility) { [weak self] in
            await self?.runBackgroundOCRIndexingLoop()
        }
    }

    private func cancelBackgroundOCRIndexing(clearQueue: Bool) {
        ocrIndexingTask?.cancel()
        ocrIndexingTask = nil

        guard clearQueue else { return }
        ocrIndexQueue.removeAll()
        queuedOCRFrameIDs.removeAll()
        recordQueueDepthTelemetry()
    }

    private func removeQueuedOCRFrames(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        guard !ocrIndexQueue.isEmpty else { return }

        ocrIndexQueue.removeAll { ids.contains($0.id) }
        queuedOCRFrameIDs.subtract(ids)
        recordQueueDepthTelemetry()
    }

    private func dequeueNextFrameForOCR() -> StoredFrame? {
        guard !ocrIndexQueue.isEmpty else { return nil }

        let frame = ocrIndexQueue.removeLast()
        queuedOCRFrameIDs.remove(frame.id)
        recordQueueDepthTelemetry()
        return frame
    }

    private func shouldContinueOCR(for frame: StoredFrame) -> Bool {
        guard !Task.isCancelled else { return false }
        guard !isBufferClearing else { return false }
        guard !ocrPruningFrameIDs.contains(frame.id) else { return false }
        return containsFrame(id: frame.id)
    }

    private func runBackgroundOCRIndexingLoop() async {
        defer {
            ocrIndexingTask = nil
            if ocrIndexingPolicy.isEnabled && !ocrIndexQueue.isEmpty {
                startBackgroundOCRIndexingIfNeeded()
            }
        }

        while !Task.isCancelled {
            guard ocrIndexingPolicy.isEnabled else { return }
            guard let frame = dequeueNextFrameForOCR() else { return }

            if Date().timeIntervalSince(frame.timestamp) > ocrIndexingPolicy.maxFrameAge {
                continue
            }

            guard shouldContinueOCR(for: frame) else {
                continue
            }

            if await textCache.hasCachedText(for: frame.id) {
                continue
            }

            do {
                let startedAt = Date()
                let image = try await frameStore.loadFullImage(id: frame.id)
                let text = await TextRecognitionManager.extractText(from: image)
                guard await cacheOCRTextIfCurrent(text, for: frame) else {
                    continue
                }

                let duration = Date().timeIntervalSince(startedAt)
                let lag = Date().timeIntervalSince(frame.timestamp)
                await searchTelemetry.recordBackgroundOCR(duration: duration, indexLag: lag)
            } catch {
                continue
            }

            let sleepDuration = ocrIndexingPolicy.minimumInterval
            if sleepDuration > 0 {
                try? await Task.sleep(for: .seconds(sleepDuration))
            }
        }
    }

    private func recordQueueDepthTelemetry() {
        let depth = ocrIndexQueue.count
        let capacity = ocrIndexingPolicy.maxQueueDepth

        Task(priority: .utility) {
            await SearchTelemetry.shared.recordQueueDepth(depth: depth, capacity: capacity)
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
