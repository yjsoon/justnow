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
    let displayID: UUID?
    let displayName: String?
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
    let concurrentJobs: Int
    let searchImageMaxPixelSize: Int

    static let disabled = OCRIndexingPolicy(
        isEnabled: false,
        minimumInterval: 0,
        maxQueueDepth: 0,
        maxFrameAge: 0,
        concurrentJobs: 1,
        searchImageMaxPixelSize: 0
    )
}

struct SearchIndexStatus: Sendable, Equatable {
    let totalFrames: Int
    let indexedFrames: Int
    let queuedFrames: Int

    var pendingFrames: Int {
        max(totalFrames - indexedFrames, 0)
    }

    static let empty = SearchIndexStatus(totalFrames: 0, indexedFrames: 0, queuedFrames: 0)
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
    let displayID: UUID?
    let displayName: String?
    let syncContinuation: CheckedContinuation<SyncIngestResult, Never>?
}

private final class CachedCGImageBox {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

@MainActor
class FrameBuffer {
    private var frames: [StoredFrame] = []
    private let frameStore: FrameStore
    private let retentionManager: RetentionManager
    private let blackFrameDetector = BlackFrameDetector.screenOff
    private lazy var ocrIndexingWorker = OCRIndexingWorker(
        dependencies: .live(frameStore: frameStore, textCache: textCache)
    )
    private var blackFrameFilterUntil: Date?
    private var saveOptions: FrameSaveOptions = .standard
    private var duplicatePolicy: DuplicateFramePolicy = .standard
    private var lastPruneCheck: Date = .distantPast
    private let pruneInterval: TimeInterval = 30
    private var ocrIndexingPolicy: OCRIndexingPolicy = .disabled
    private var ocrFrameQueue = OCRFrameQueue()
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
    private let thumbnailCache = NSCache<NSUUID, CachedCGImageBox>()
    private let fullImageCache = NSCache<NSUUID, CachedCGImageBox>()
    private var inFlightFullImageLoads: [UUID: Task<CachedCGImageBox, Error>] = [:]

    // OCR text cache for faster subsequent searches
    let textCache = TextCache()

    init(retentionPolicy: RetentionPolicy) async throws {
        self.frameStore = try FrameStore()
        self.retentionManager = RetentionManager(policy: retentionPolicy)
        thumbnailCache.countLimit = 100
        fullImageCache.countLimit = 24

        // Load persisted frames
        await loadPersistedFrames()

        // Cleanup orphaned files
        try await frameStore.cleanupOrphans()

        // Prune stale text cache entries
        let validIDs = Set(frames.map { $0.id })
        await textCache.prune(keepingFrameIDs: validIDs)
    }

    // MARK: - Capture

    func addFrame(_ cgImage: CGImage, timestamp: Date, display: DisplayInfo?) {
        // Skip black frames only during sleep/wake transitions.
        if shouldCheckBlackFrame(at: timestamp) && blackFrameDetector.isBlackFrame(cgImage) {
            print("Skipping black frame")
            return
        }

        enqueueIngest(
            cgImage: cgImage,
            timestamp: timestamp,
            display: display,
            syncContinuation: nil,
            prioritiseSync: false
        )
    }

    /// Add a frame synchronously (awaits save completion). Used when opening overlay.
    func addFrameSync(_ cgImage: CGImage, timestamp: Date, display: DisplayInfo?) async {
        if shouldCheckBlackFrame(at: timestamp) && blackFrameDetector.isBlackFrame(cgImage) {
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
                    display: display,
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
    /// When `displayID` is set, frames are filtered to that display. Pass
    /// `includeLegacyFrames` for the primary-display slot so pre-multi-display
    /// captures remain visible.
    func getFilteredFrames(
        hashThreshold: Int = 3,
        recentWindow: TimeInterval = 300,
        maximumAge: TimeInterval? = nil,
        displayID: UUID? = nil,
        includeLegacyFrames: Bool = false
    ) -> [StoredFrame] {
        guard !frames.isEmpty else { return [] }

        let now = Date()
        var candidateFrames: [StoredFrame]
        if let maximumAge {
            let cutoff = now.addingTimeInterval(-maximumAge)
            candidateFrames = frames.filter { $0.timestamp >= cutoff }
        } else {
            candidateFrames = frames
        }
        if let displayID {
            candidateFrames = candidateFrames.filter { frame in
                if let frameDisplayID = frame.displayID {
                    return frameDisplayID == displayID
                }
                return includeLegacyFrames
            }
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

    /// Displays that have at least one frame in the buffer. Ordered by most
    /// recent capture first so the overlay can surface active displays before
    /// ones that have gone quiet.
    func knownDisplays() -> [(id: UUID, name: String)] {
        var seen: Set<UUID> = []
        var ordered: [(id: UUID, name: String)] = []
        for frame in frames.reversed() {
            guard let id = frame.displayID else { continue }
            if seen.insert(id).inserted {
                ordered.append((id, frame.displayName ?? "Display"))
            }
        }
        return ordered
    }

    var hasLegacyFrames: Bool {
        frames.contains { $0.displayID == nil }
    }

    var frameCount: Int {
        frames.count
    }

    func searchIndexStatus() async -> SearchIndexStatus {
        let indexedFrames = min(await textCache.count, frames.count)
        return SearchIndexStatus(
            totalFrames: frames.count,
            indexedFrames: indexedFrames,
            queuedFrames: ocrFrameQueue.count
        )
    }

    /// Load full-resolution image from disk
    func getFullImage(for frame: StoredFrame) async throws -> CGImage {
        try await loadFullImageBox(for: frame).image
    }

    func prefetchFullImages(for frames: [StoredFrame]) async {
        for frame in frames {
            guard !Task.isCancelled else { return }
            _ = try? await loadFullImageBox(for: frame)
        }
    }

    func getSearchLayout(for frame: StoredFrame, image: CGImage? = nil) async -> SearchTextLayout? {
        if let cached = await textCache.getSearchLayout(for: frame.id) {
            return cached
        }

        guard shouldContinueOCR(for: frame) else { return nil }

        do {
            let sourceImage: CGImage
            if let image {
                sourceImage = image
            } else {
                sourceImage = try await frameStore.loadFullImage(id: frame.id)
            }

            guard !Task.isCancelled else { return nil }
            guard let layout = await TextRecognitionManager.extractSearchLayout(from: sourceImage),
                  !layout.isEmpty else {
                return nil
            }
            guard shouldContinueOCR(for: frame) else { return nil }

            await textCache.setSearchLayout(layout, for: frame.id, timestamp: frame.timestamp)
            return layout
        } catch {
            return nil
        }
    }

    /// Get thumbnail, with caching
    func getThumbnail(for frame: StoredFrame) async -> CGImage? {
        let key = frame.id as NSUUID

        if let cached = thumbnailCache.object(forKey: key) {
            return cached.image
        }

        guard let cgImage = await frameStore.loadThumbnail(id: frame.id) else {
            return nil
        }

        thumbnailCache.setObject(CachedCGImageBox(cgImage), forKey: key)
        return cgImage
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
        fullImageCache.removeAllObjects()
        inFlightFullImageLoads.removeAll()
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

        enqueueStoredFramesForBackgroundOCR()
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
            .map {
                StoredFrame(
                    id: $0.id,
                    timestamp: $0.timestamp,
                    hash: $0.hash,
                    displayID: $0.displayID,
                    displayName: $0.displayName
                )
            }
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

    private func loadFullImageBox(for frame: StoredFrame) async throws -> CachedCGImageBox {
        let key = frame.id as NSUUID
        if let cached = fullImageCache.object(forKey: key) {
            return cached
        }

        if let inFlight = inFlightFullImageLoads[frame.id] {
            return try await inFlight.value
        }

        let store = frameStore
        let loadTask = Task(priority: .userInitiated) {
            let image = try await store.loadFullImage(id: frame.id)
            return CachedCGImageBox(image)
        }
        inFlightFullImageLoads[frame.id] = loadTask

        do {
            let cachedImage = try await loadTask.value
            fullImageCache.setObject(cachedImage, forKey: key)
            inFlightFullImageLoads.removeValue(forKey: frame.id)
            return cachedImage
        } catch {
            inFlightFullImageLoads.removeValue(forKey: frame.id)
            throw error
        }
    }

    private func enqueueIngest(
        cgImage: CGImage,
        timestamp: Date,
        display: DisplayInfo?,
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
            displayID: display?.id,
            displayName: display?.name,
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
                displayID: work.displayID,
                displayName: work.displayName,
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
        displayID: UUID?,
        displayName: String?,
        ingestGeneration generation: Int
    ) async -> SyncIngestResult {
        guard generation == ingestGeneration else { return .retryAfterClear }
        guard shouldStoreFrame(hash: hash, timestamp: timestamp, displayID: displayID) else { return .completed }
        do {
            let metadata = try await frameStore.saveFrame(
                cgImage,
                timestamp: timestamp,
                hash: hash,
                displayID: displayID,
                displayName: displayName,
                options: saveOptions
            )
            guard generation == ingestGeneration else {
                try? await frameStore.pruneFrames(ids: [metadata.id])
                return .retryAfterClear
            }
            let frame = StoredFrame(
                id: metadata.id,
                timestamp: metadata.timestamp,
                hash: metadata.hash,
                displayID: metadata.displayID,
                displayName: metadata.displayName
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

    private func shouldStoreFrame(hash: UInt64, timestamp: Date, displayID: UUID?) -> Bool {
        let insertionIndex = frameInsertionIndex(for: timestamp)
        var index = insertionIndex - 1
        while index >= 0 {
            let candidate = frames[index]
            if candidate.displayID == displayID {
                guard candidate.hash != 0 else { return true }
                let timeSinceLast = timestamp.timeIntervalSince(candidate.timestamp)
                guard timeSinceLast < duplicatePolicy.minimumSpacing else { return true }
                let distance = PerceptualHash.hammingDistance(hash, candidate.hash)
                return distance > duplicatePolicy.hashThreshold
            }
            index -= 1
        }
        return true
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
        let policy = ocrIndexingPolicy
        if let minimumTimestamp = minimumQueuedOCRFrameTimestamp(for: policy),
           frame.timestamp < minimumTimestamp {
            return
        }
        guard ocrFrameQueue.enqueue(frame) else { return }

        applyOCRQueuePolicy(policy)
        updateOCRIndexQueueState()
        startBackgroundOCRIndexingIfNeeded()
    }

    private func enqueueStoredFramesForBackgroundOCR() {
        let policy = ocrIndexingPolicy
        let minimumTimestamp = minimumQueuedOCRFrameTimestamp(for: policy)
        let eligibleFrames: [StoredFrame]
        if let minimumTimestamp {
            eligibleFrames = frames.filter { $0.timestamp >= minimumTimestamp }
        } else {
            eligibleFrames = frames
        }

        ocrFrameQueue.enqueue(contentsOf: eligibleFrames)
        applyOCRQueuePolicy(policy)
        updateOCRIndexQueueState()
    }

    /// Keep telemetry current without dropping retained frames from the indexing backlog.
    private func updateOCRIndexQueueState() {
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
        ocrFrameQueue.clear()
        recordQueueDepthTelemetry()
    }

    private func removeQueuedOCRFrames(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        guard !ocrFrameQueue.isEmpty else { return }

        ocrFrameQueue.remove(ids: ids)
        recordQueueDepthTelemetry()
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
            if ocrIndexingPolicy.isEnabled && !ocrFrameQueue.isEmpty {
                startBackgroundOCRIndexingIfNeeded()
            }
        }

        while !Task.isCancelled {
            guard ocrIndexingPolicy.isEnabled else { return }
            let policy = ocrIndexingPolicy
            applyOCRQueuePolicy(policy)
            recordQueueDepthTelemetry()
            let dequeuedFrames = ocrFrameQueue.dequeue(limit: policy.concurrentJobs)
            recordQueueDepthTelemetry()
            guard !dequeuedFrames.isEmpty else { return }

            let framesToIndex = dequeuedFrames.filter(shouldContinueOCR(for:))
            let indexedFrames = await ocrIndexingWorker.index(
                frames: framesToIndex,
                searchImageMaxPixelSize: policy.searchImageMaxPixelSize
            )

            for indexedFrame in indexedFrames {
                guard !Task.isCancelled else { return }
                guard await cacheOCRTextIfCurrent(indexedFrame.text, for: indexedFrame.frame) else {
                    continue
                }

                await searchTelemetry.recordBackgroundOCR(
                    duration: indexedFrame.duration,
                    indexLag: indexedFrame.indexLag
                )
            }

            let sleepDuration = policy.minimumInterval
            if sleepDuration > 0 {
                try? await Task.sleep(for: .seconds(sleepDuration))
            }
        }
    }

    private func recordQueueDepthTelemetry() {
        let depth = ocrFrameQueue.count
        let capacity = ocrIndexingPolicy.maxQueueDepth

        Task(priority: .utility) {
            await SearchTelemetry.shared.recordQueueDepth(depth: depth, capacity: capacity)
        }
    }

    private func applyOCRQueuePolicy(_ policy: OCRIndexingPolicy) {
        if let minimumTimestamp = minimumQueuedOCRFrameTimestamp(for: policy) {
            ocrFrameQueue.discardOlderThan(minimumTimestamp)
        }
        ocrFrameQueue.trimToNewest(maxDepth: policy.maxQueueDepth)
    }

    private func minimumQueuedOCRFrameTimestamp(for policy: OCRIndexingPolicy, now: Date = Date()) -> Date? {
        guard policy.maxFrameAge > 0 else { return nil }
        return now.addingTimeInterval(-policy.maxFrameAge)
    }

    private func shouldCheckBlackFrame(at timestamp: Date) -> Bool {
        guard let until = blackFrameFilterUntil else { return false }
        return timestamp <= until
    }
}
