//
//  FrameBuffer.swift
//  JustNow
//

import AppKit
import Foundation
import os.log

private let captureLogger = Logger(subsystem: "sg.tk.JustNow", category: "Capture")

struct DuplicateFramePolicy: Sendable, Equatable {
    let hashThreshold: Int
    let minimumSpacing: TimeInterval

    static let standard = DuplicateFramePolicy.exact(atMostEvery: AppStorageDefault.captureInterval)
    static let lowPower = DuplicateFramePolicy(hashThreshold: 1, minimumSpacing: 5)

    static func exact(atMostEvery interval: TimeInterval) -> DuplicateFramePolicy {
        let clampedInterval = max(interval, 0.25)
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

enum FrameBufferCaptureSessionError: Error, Equatable {
    case alreadyActive(UUID?)
}

enum FrameBufferClearError: LocalizedError {
    case captureResumeFailed(String)
    case cleanupIncomplete([String])
    case cleanupIncompleteAndCaptureResumeFailed([String], String)

    var errorDescription: String? {
        switch self {
        case .captureResumeFailed(let detail):
            "History was cleared, but capture could not resume. JustNow will retry automatically. \(detail)"
        case .cleanupIncomplete(let failures):
            "History was removed from the timeline, but some stored data could not be deleted. Try Clear All History again.\n\(Self.boundedCleanupDescription(failures))"
        case .cleanupIncompleteAndCaptureResumeFailed(let failures, let detail):
            "History was removed from the timeline, but some stored data could not be deleted and capture could not resume. Try Clear All History again; JustNow will retry capture automatically.\n\(Self.boundedCleanupDescription(failures))\n\(detail)"
        }
    }

    private static func boundedCleanupDescription(_ paths: [String]) -> String {
        let names = paths.prefix(5).map { URL(fileURLWithPath: $0).lastPathComponent }
        let remainder = max(0, paths.count - names.count)
        let visible = names.map { "• \($0)" }.joined(separator: "\n")
        return remainder > 0 ? "\(visible)\n…and \(remainder) more." : visible
    }
}

private enum CaptureDisplayKey: Hashable {
    case legacy
    case display(UUID)

    init(_ displayID: UUID?) {
        self = displayID.map(Self.display) ?? .legacy
    }
}

private struct AcceptedCaptureObservation {
    let hash: UInt64
    let timestamp: Date
}

private struct PendingCaptureSessionClose {
    let session: CaptureSession
    let reason: CaptureSessionEndReason
}

private struct PendingIngest {
    let cgImage: CGImage
    let timestamp: Date
    let generation: Int
    let displayID: UUID?
    let displayName: String?
    let syncContinuation: CheckedContinuation<SyncIngestResult, Never>?
}

/// Performs the one capture JPEG encode on Swift's concurrent executor. The
/// operation is injectable so tests can verify both scheduling and exact-byte
/// handoff without asking ImageIO to produce a particular payload.
nonisolated struct FrameJPEGEncoder: Sendable {
    typealias Operation = @Sendable (CGImage, CGFloat) -> Data?

    private let operation: Operation

    init(operation: @escaping Operation = { image, quality in
        ImageEncoder.jpegData(from: image, quality: quality)
    }) {
        self.operation = operation
    }

    @concurrent
    func encode(_ image: CGImage, quality: CGFloat) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let data = operation(image, quality)
        guard !Task.isCancelled else { return nil }
        return data
    }
}

@MainActor
class FrameBuffer {
    private var frames: [StoredFrame] = []
    private var frameLookup: [UUID: StoredFrame] = [:]
    private var timelineEntries: [TimelineEntry] = []
    /// SQLite returns equal-time spans in durable insertion order. Preserve
    /// that ordering in memory without adding another persisted column.
    private var timelineOrderBySpanID: [UUID: Int] = [:]
    private var nextTimelineOrder = 0
    /// Background OCR is deliberately durable-only in hybrid mode. Volatile
    /// payloads remain available for direct text grab and image viewing.
    private var durablePhysicalFrameIDs: Set<UUID> = []
    private var lastAcceptedObservation: [CaptureDisplayKey: AcceptedCaptureObservation] = [:]
    private let captureInstrumentation: CapturePersistenceInstrumentation
    private let diagnosticsLog: CaptureInstrumentationLogSink?
    private let frameRepository: any FrameRepository
    /// Effective source configuration fixed when this buffer was constructed.
    /// Saved Settings changes are intentionally compared against this value.
    let historyStorageMode: HistoryStorageMode
    private let jpegEncoder: FrameJPEGEncoder
    private let retentionManager: RetentionManager
    private let blackFrameDetector = BlackFrameDetector.screenOff
    private lazy var ocrIndexingWorker = OCRIndexingWorker(
        dependencies: .live(frameRepository: frameRepository, textCache: textCache)
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
    /// During post-clear recovery, retain at most the newest decoded capture
    /// per display instead of one potentially huge `CGImage` per capture tick.
    private struct PendingRecoveryFrame {
        let cgImage: CGImage
        let timestamp: Date
        let display: DisplayInfo?
        let intentGeneration: Int
        let recoveryGeneration: Int
    }
    private var pendingRecoveryFrames: [CaptureDisplayKey: PendingRecoveryFrame] = [:]
    private var recoveryFrameTask: Task<Void, Never>?
    private var recoveryFrameTaskSerial = 0
    private var recoveryFrameGeneration = 0
    private let maxIngestBacklog = 6
    private static let captureInstrumentationDiagnosticInterval: TimeInterval = 300
    private var lastCaptureInstrumentationDiagnosticAt: Date = .distantPast
    /// Bumped in `clear()` so in-flight ingest work can drop results and avoid racing a reset buffer.
    private var ingestGeneration = 0
    /// Epoch for repository results that can change the in-memory projection.
    /// Clear bypasses the reconciliation gate, so work admitted before the
    /// reset must not apply stale effects after it returns.
    private var repositoryEffectGeneration = 0
    /// While true, new captures are not queued and disk reset is in progress — avoids races with `frames.removeAll()` and ingest teardown.
    private var isBufferClearing = false
    /// Pressure maintenance drains already-admitted ingest before repository
    /// eviction, then blocks new admission until its effects are reconciled.
    private var isMemoryPressureMaintenanceActive = false
    private var isCaptureSessionActive = false
    /// Desired coordinator state, kept separate from the currently open store
    /// session so stop/start intent survives actor re-entrancy during clear.
    private var captureSessionIntentActive = false
    private var captureSessionIntentGeneration = 0
    private var activeCaptureSession: CaptureSession?
    private var pendingCaptureSessionClose: PendingCaptureSessionClose?
    /// Orders capture lifecycle intent and repository session ownership. This
    /// stays separate from effect reconciliation so clear can overtake a
    /// suspended save without begin/end overtaking clear or each other.
    private let captureSessionGate = CaptureReconciliationGate()
    /// Serialises every repository mutation through application of its
    /// source-neutral effects. No later maintenance/prune/session operation
    /// can overtake a suspended mutation and resurrect stale timeline state.
    private let repositoryReconciliationGate = CaptureReconciliationGate()
    private var activeClearOperationCount = 0
    private var clearWaiters: [(id: UUID, continuation: CheckedContinuation<ClearWaitResult, Never>)] = []
    private let searchTelemetry = SearchTelemetry.shared

    // Pause pruning while overlay is open to prevent "Frame removed" issues
    var isPruningPaused: Bool = false

    // Thumbnail cache for quick access
    private let thumbnailCache = NSCache<NSUUID, CGImage>()
    private let fullImageCache = NSCache<NSUUID, CGImage>()
    private var inFlightFullImageLoads: [UUID: Task<CGImage, Error>] = [:]
    private var decodedCacheGeneration = 0

    private static let fullImageCacheByteBudget: Int = 256 * 1024 * 1024
    private static let thumbnailCacheByteBudget: Int = 16 * 1024 * 1024

    private static func byteCost(of image: CGImage) -> Int {
        // Decoded bitmap size — `bytesPerRow * height` is a tight approximation
        // even when the underlying surface uses extra padding.
        max(image.bytesPerRow * image.height, image.width * image.height * 4)
    }

    // OCR text cache for faster subsequent searches
    let textCache: TextCache

    /// `storageDirectory` is injectable so tests can point frame persistence
    /// and the OCR cache at a temporary directory. Production uses the
    /// default Application Support location.
    init(
        retentionPolicy: RetentionPolicy,
        storageDirectory: URL? = nil,
        diagnosticsLog: CaptureInstrumentationLogSink?,
        frameRepository: (any FrameRepository)? = nil,
        historyStorageMode: HistoryStorageMode? = nil,
        jpegEncoder: FrameJPEGEncoder = FrameJPEGEncoder()
    ) async throws {
        let instrumentation = CapturePersistenceInstrumentation()
        self.captureInstrumentation = instrumentation
        self.diagnosticsLog = diagnosticsLog
        self.jpegEncoder = jpegEncoder
        let resolvedHistoryStorageMode = historyStorageMode ?? HistoryStorageMode.launchDefault()
        self.historyStorageMode = resolvedHistoryStorageMode
        if let frameRepository {
            self.frameRepository = frameRepository
        } else {
            let frameStore = try FrameStore(
                directory: storageDirectory,
                instrumentation: instrumentation
            )
            switch resolvedHistoryStorageMode {
            case .allDisk:
                self.frameRepository = DiskFrameRepository(frameStore: frameStore)
            case .hybridRAM(let byteCap):
                self.frameRepository = HybridFrameRepository(frameStore: frameStore, byteCap: byteCap)
            }
        }
        self.textCache = TextCache(directory: storageDirectory)
        self.retentionManager = RetentionManager(policy: retentionPolicy)
        // A single 5K BGRA frame is ~58 MB decoded. `countLimit` lets 24 of
        // those pin ~1.4 GB; switch to byte budgets so the cache evicts under
        // real memory pressure.
        thumbnailCache.countLimit = 200
        thumbnailCache.totalCostLimit = Self.thumbnailCacheByteBudget
        fullImageCache.countLimit = 12
        fullImageCache.totalCostLimit = Self.fullImageCacheByteBudget

        // Reconcile disk and database before materialising the in-memory
        // timeline, so rows whose full JPEG disappeared never become phantom
        // frames for the rest of this launch.
        try await self.frameRepository.cleanupOrphans()

        // Load persisted frames
        await loadPersistedFrames()

        // Prune stale text cache entries
        let validIDs = Set(frames.map { $0.id })
        await textCache.prune(keepingFrameIDs: validIDs)
        // The scheduled report is deliberately delayed; `flushCaches()` emits
        // the one final aggregate line for short sessions.
        lastCaptureInstrumentationDiagnosticAt = Date()
    }

    // MARK: - Capture

    func addFrame(_ cgImage: CGImage, timestamp: Date, display: DisplayInfo?) {
        guard !isMemoryPressureMaintenanceActive,
              isCaptureSessionActive || captureSessionIntentActive else { return }
        captureInstrumentation.recordCapturedFrame(displayID: display?.id)
        // Skip black frames only during sleep/wake transitions.
        if shouldCheckBlackFrame(at: timestamp) && blackFrameDetector.isBlackFrame(cgImage) {
            captureLogger.debug("Skipping black frame")
            return
        }

        if isCaptureSessionActive {
            enqueueIngest(
                cgImage: cgImage,
                timestamp: timestamp,
                display: display,
                syncContinuation: nil,
                prioritiseSync: false
            )
        } else {
            // A durable reopen after clear may fail transiently while capture
            // intent remains live. Keep only the newest observation per display
            // to drive the next serialised reopen attempt without unbounded
            // decoded-image retention.
            enqueueRecoveryFrame(cgImage, timestamp: timestamp, display: display)
        }
    }

    private func enqueueRecoveryFrame(
        _ cgImage: CGImage,
        timestamp: Date,
        display: DisplayInfo?
    ) {
        let key = CaptureDisplayKey(display?.id)
        let pending = PendingRecoveryFrame(
            cgImage: cgImage,
            timestamp: timestamp,
            display: display,
            intentGeneration: captureSessionIntentGeneration,
            recoveryGeneration: recoveryFrameGeneration
        )
        if let existing = pendingRecoveryFrames[key], existing.timestamp >= pending.timestamp {
            return
        }
        pendingRecoveryFrames[key] = pending
        guard recoveryFrameTask == nil else { return }
        recoveryFrameTaskSerial += 1
        let taskSerial = recoveryFrameTaskSerial
        recoveryFrameTask = Task { @MainActor [weak self] in
            await self?.drainRecoveryFrames(taskSerial: taskSerial)
        }
    }

    private func drainRecoveryFrames(taskSerial: Int) async {
        defer {
            if recoveryFrameTaskSerial == taskSerial {
                recoveryFrameTask = nil
            }
        }
        while !Task.isCancelled,
              captureSessionIntentActive,
              let next = pendingRecoveryFrames.values.max(by: { $0.timestamp < $1.timestamp }) {
            pendingRecoveryFrames[CaptureDisplayKey(next.display?.id)] = nil
            await addFrameSyncAfterValidation(
                next.cgImage,
                timestamp: next.timestamp,
                display: next.display,
                intentGeneration: next.intentGeneration,
                recoveryGeneration: next.recoveryGeneration
            )
        }
        if !captureSessionIntentActive {
            pendingRecoveryFrames.removeAll(keepingCapacity: false)
        }
    }

    /// Add a frame synchronously (awaits save completion). Used when opening overlay.
    func addFrameSync(_ cgImage: CGImage, timestamp: Date, display: DisplayInfo?) async {
        guard !isMemoryPressureMaintenanceActive,
              isCaptureSessionActive || captureSessionIntentActive || isBufferClearing else { return }
        captureInstrumentation.recordCapturedFrame(displayID: display?.id)
        if shouldCheckBlackFrame(at: timestamp) && blackFrameDetector.isBlackFrame(cgImage) {
            return
        }

        await addFrameSyncAfterValidation(cgImage, timestamp: timestamp, display: display)
    }

    private func addFrameSyncAfterValidation(
        _ cgImage: CGImage,
        timestamp: Date,
        display: DisplayInfo?,
        intentGeneration: Int? = nil,
        recoveryGeneration: Int? = nil
    ) async {

        while !Task.isCancelled {
            if let intentGeneration,
               intentGeneration != captureSessionIntentGeneration {
                return
            }
            if let recoveryGeneration,
               recoveryGeneration != recoveryFrameGeneration {
                return
            }
            do {
                try await waitUntilNotClearing()
            } catch is CancellationError {
                return
            } catch {
                return
            }

            guard !Task.isCancelled,
                  captureSessionIntentActive,
                  intentGeneration == nil || intentGeneration == captureSessionIntentGeneration,
                  recoveryGeneration == nil || recoveryGeneration == recoveryFrameGeneration else {
                return
            }
            if !isCaptureSessionActive {
                do {
                    try await recoverCaptureSessionIfNeeded(at: timestamp)
                } catch is CancellationError {
                    return
                } catch {
                    let detail = DiagnosticsLogFormat.describe(error)
                    captureLogger.error("Failed to resume capture history after clear: \(detail, privacy: .public)")
                    DiagnosticsLog.shared.log(
                        "Capture",
                        "Failed to resume capture history after clear: \(detail); retrying with a later frame"
                    )
                    return
                }
            }
            guard !Task.isCancelled,
                  isCaptureSessionActive,
                  intentGeneration == nil || intentGeneration == captureSessionIntentGeneration,
                  recoveryGeneration == nil || recoveryGeneration == recoveryFrameGeneration else {
                return
            }

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

    func getTimelineEntries() -> [TimelineEntry] {
        timelineEntries
    }

    func containsFrame(id: UUID) -> Bool {
        frameLookup[id] != nil
    }

    /// Physical payload IDs can be shared by more than one logical span. UI
    /// snapshots therefore validate their span identity, not merely whether a
    /// different span still references the same JPEG.
    func containsTimelineSpan(id: UUID) -> Bool {
        timelineEntries.contains { $0.span.id == id }
    }

    /// Return frames for the provided IDs in the same order as the IDs.
    func frames(withIDs ids: [UUID]) -> [StoredFrame] {
        guard !ids.isEmpty else { return [] }

        var matchedFrames: [StoredFrame] = []
        matchedFrames.reserveCapacity(ids.count)

        for id in ids {
            guard let frame = frameLookup[id] else { continue }
            matchedFrames.append(frame)
        }

        return matchedFrames
    }

    /// Return every logical span whose physical JPEG is one of `ids`.
    ///
    /// OCR remains keyed by the physical frame ID, while browsing is keyed by
    /// the logical span ID. A physical payload may therefore produce more than
    /// one result here. Results retain the durable timeline order rather than
    /// the cache's relevance/recency ordering.
    func timelineEntries(
        matchingPhysicalFrameIDs ids: [UUID],
        since cutoff: Date? = nil,
        displayID: UUID? = nil,
        includeLegacyFrames: Bool = false
    ) -> [TimelineEntry] {
        guard !ids.isEmpty else { return [] }
        let matchedIDs = Set(ids)

        return timelineEntries.filter { entry in
            guard matchedIDs.contains(entry.frame.id) else { return false }
            if let cutoff, timelineSpanBounds(for: entry).end < cutoff {
                return false
            }
            if let displayID {
                if let entryDisplayID = entry.span.displayID {
                    return entryDisplayID == displayID
                }
                return includeLegacyFrames
            }
            return true
        }
    }

    func cacheOCRTextIfCurrent(_ text: String, for frame: StoredFrame) async -> Bool {
        guard let currentTimestamp = currentOCRCacheTimestamp(for: frame) else { return false }
        await textCache.setText(text, for: frame.id, timestamp: currentTimestamp)

        guard shouldContinueOCR(for: frame) else {
            await textCache.removeText(for: frame.id)
            return false
        }

        return true
    }

    /// Commits a generated layout using the physical frame's current logical
    /// projection. OCR can begin before an exact-payload span extension; if no
    /// cache row existed when that extension occurred, the queued frame's
    /// timestamp is stale by the time generation finishes.
    func cacheSearchLayoutIfCurrent(_ layout: SearchTextLayout, for frame: StoredFrame) async -> Bool {
        guard let currentTimestamp = currentOCRCacheTimestamp(for: frame) else { return false }
        await textCache.setSearchLayout(layout, for: frame.id, timestamp: currentTimestamp)

        guard shouldContinueOCR(for: frame) else {
            await textCache.removeText(for: frame.id)
            return false
        }

        return true
    }

    /// Get logical timeline spans with near-duplicates removed for smoother
    /// browsing. Recency and maximum age use the span's latest proved
    /// observation, not the physical JPEG's original capture date.
    func getFilteredTimelineEntries(
        hashThreshold: Int = 3,
        recentWindow: TimeInterval = 300,
        maximumAge: TimeInterval? = nil,
        displayID: UUID? = nil,
        includeLegacyFrames: Bool = false,
        now: Date = Date()
    ) -> [TimelineEntry] {
        filteredTimelineEntries(
            from: timelineEntries,
            hashThreshold: hashThreshold,
            recentWindow: recentWindow,
            maximumAge: maximumAge,
            displayID: displayID,
            includeLegacyFrames: includeLegacyFrames,
            now: now
        )
    }

    func filteredTimelineEntries(
        from sourceEntries: [TimelineEntry],
        hashThreshold: Int = 3,
        recentWindow: TimeInterval = 300,
        maximumAge: TimeInterval? = nil,
        displayID: UUID? = nil,
        includeLegacyFrames: Bool = false,
        now: Date = Date()
    ) -> [TimelineEntry] {
        guard !sourceEntries.isEmpty else { return [] }

        var candidates: [TimelineEntry]
        if let maximumAge {
            let cutoff = now.addingTimeInterval(-maximumAge)
            candidates = sourceEntries.filter { timelineSpanBounds(for: $0).end >= cutoff }
        } else {
            candidates = sourceEntries
        }
        if let displayID {
            candidates = candidates.filter { entry in
                if let entryDisplayID = entry.span.displayID {
                    return entryDisplayID == displayID
                }
                return includeLegacyFrames
            }
        }

        var filtered: [TimelineEntry] = []
        var lastHashByDisplay: [CaptureDisplayKey: UInt64] = [:]

        for entry in candidates {
            let displayKey = CaptureDisplayKey(entry.span.displayID)
            let age = now.timeIntervalSince(timelineSpanBounds(for: entry).end)

            // Keep every logical span in the recent window.
            if age <= recentWindow {
                filtered.append(entry)
                if entry.frame.hash == 0 {
                    lastHashByDisplay.removeValue(forKey: displayKey)
                } else {
                    lastHashByDisplay[displayKey] = entry.frame.hash
                }
                continue
            }

            // Legacy frames without hash (hash=0) always kept, reset comparison chain
            guard entry.frame.hash != 0 else {
                filtered.append(entry)
                lastHashByDisplay.removeValue(forKey: displayKey)
                continue
            }

            // Use stronger dedupe only once frames age out of the recent navigation window.
            let threshold = hashThreshold

            // Keep if different enough from last kept frame
            let isDifferent = lastHashByDisplay[displayKey].map {
                PerceptualHash.hammingDistance(entry.frame.hash, $0) > threshold
            } ?? true
            if isDifferent {
                filtered.append(entry)
                lastHashByDisplay[displayKey] = entry.frame.hash
            }
        }

        return filtered
    }

    /// Compatibility projection for callers that still consume physical
    /// frames. New timeline UI should use `getFilteredTimelineEntries` so span
    /// identity and coverage are not lost.
    func getFilteredFrames(
        hashThreshold: Int = 3,
        recentWindow: TimeInterval = 300,
        maximumAge: TimeInterval? = nil,
        displayID: UUID? = nil,
        includeLegacyFrames: Bool = false,
        now: Date = Date()
    ) -> [StoredFrame] {
        getFilteredTimelineEntries(
            hashThreshold: hashThreshold,
            recentWindow: recentWindow,
            maximumAge: maximumAge,
            displayID: displayID,
            includeLegacyFrames: includeLegacyFrames,
            now: now
        ).map(Self.browsingFrame(from:))
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
        let physicalFrameCount = Set(timelineEntries.map(\.frame.id)).count
        let indexedFrames = min(await textCache.count, physicalFrameCount)
        return SearchIndexStatus(
            totalFrames: physicalFrameCount,
            indexedFrames: indexedFrames,
            queuedFrames: ocrFrameQueue.count
        )
    }

    /// The overlay holds this lease for its complete visible snapshot. Disk
    /// repositories return a no-op lease; hybrid repositories pin only the
    /// volatile payload IDs that are currently present.
    func acquirePayloadLease(for frames: [StoredFrame]) async -> any FrameRepositoryPayloadLease {
        await frameRepository.acquirePayloadLease(for: Set(frames.map(\.id)))
    }

    /// The overlay can switch displays after it appears, so lease the entire
    /// source timeline rather than only its initially filtered display.
    func acquireCurrentTimelineSnapshotLease() async -> FrameRepositoryLeasedTimelineSnapshot {
        await frameRepository.acquireCurrentTimelineSnapshotLease()
    }

    func payloadResolutionStatistics() async -> FramePayloadResolutionStatistics {
        await frameRepository.payloadResolutionStatistics()
    }

    /// Releases a source snapshot and applies any deferred RAM trim before the
    /// overlay is allowed to resume capture.
    @discardableResult
    func releasePayloadLease(
        _ lease: any FrameRepositoryPayloadLease
    ) async -> FrameRepositoryMaintenanceResult {
        let generation = repositoryEffectGeneration
        return await repositoryReconciliationGate.withPermitIgnoringCancellation {
            let result = await lease.release()
            guard generation == self.repositoryEffectGeneration else { return result }
            await self.applyRepositoryMaintenance(result)
            return result
        }
    }

    func applyRepositoryMaintenance(
        _ result: FrameRepositoryMaintenanceResult
    ) async {
        await applyRepositoryEffects(result.effects)
    }

    /// Load full-resolution image from disk
    func getFullImage(for frame: StoredFrame) async throws -> CGImage {
        try await loadFullImage(for: frame)
    }

    func prefetchFullImages(for frames: [StoredFrame]) async {
        for frame in frames {
            guard !Task.isCancelled else { return }
            _ = try? await loadFullImage(for: frame)
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
                sourceImage = try await frameRepository.loadFullImage(id: frame.id)
            }

            guard !Task.isCancelled else { return nil }
            guard let layout = await TextRecognitionManager.extractSearchLayout(from: sourceImage),
                  !layout.isEmpty else {
                return nil
            }
            guard await cacheSearchLayoutIfCurrent(layout, for: frame) else { return nil }
            return layout
        } catch {
            return nil
        }
    }

    /// Copy the frame's stored JPEG (full original pixel dimensions) to the
    /// user's chosen screenshots location. Returns the destination URL.
    func saveFrameToScreenshotsLocation(
        _ frame: StoredFrame,
        timestamp: Date? = nil
    ) async throws -> URL {
        try await frameRepository.exportFrame(id: frame.id, timestamp: timestamp ?? frame.timestamp)
    }

    /// Encode an in-memory cropped CGImage as JPEG and save it to the user's
    /// chosen screenshots location. Used for screenshot-region drags from
    /// the rewind overlay.
    func saveCroppedImageToScreenshotsLocation(_ image: CGImage, timestamp: Date = Date()) async throws -> URL {
        try await frameRepository.exportCroppedImage(image, timestamp: timestamp)
    }

    /// Get thumbnail, with caching
    func getThumbnail(for frame: StoredFrame) async -> CGImage? {
        let key = frame.id as NSUUID

        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }

        let generation = decodedCacheGeneration
        guard let cgImage = await frameRepository.loadThumbnail(id: frame.id) else {
            return nil
        }

        if generation == decodedCacheGeneration, frameLookup[frame.id] != nil {
            thumbnailCache.setObject(cgImage, forKey: key, cost: Self.byteCost(of: cgImage))
        }
        return cgImage
    }

    // MARK: - Management

    @discardableResult
    func beginCaptureSession(at startedAt: Date = Date()) async throws -> CaptureSession {
        try await captureSessionGate.withPermitIgnoringCancellation {
            try await self.beginCaptureSessionWithLifecyclePermit(at: startedAt)
        }
    }

    private func beginCaptureSessionWithLifecyclePermit(
        at startedAt: Date
    ) async throws -> CaptureSession {
        guard !captureSessionIntentActive else {
            throw FrameBufferCaptureSessionError.alreadyActive(activeCaptureSession?.id)
        }
        captureSessionIntentGeneration += 1
        let generation = captureSessionIntentGeneration
        let repositoryGeneration = repositoryEffectGeneration
        captureSessionIntentActive = true
        do {
            return try await repositoryReconciliationGate.withPermitIgnoringCancellation {
                guard repositoryGeneration == self.repositoryEffectGeneration else {
                    throw CancellationError()
                }
                try await self.retryPendingCaptureSessionCloseIfNeeded(
                    repositoryGeneration: repositoryGeneration
                )
                guard repositoryGeneration == self.repositoryEffectGeneration else {
                    throw CancellationError()
                }
                guard self.activeCaptureSession == nil else {
                    throw FrameBufferCaptureSessionError.alreadyActive(
                        self.activeCaptureSession?.id
                    )
                }
                let session = try await self.frameRepository.beginCaptureSession(at: startedAt)
                guard repositoryGeneration == self.repositoryEffectGeneration else {
                    throw CancellationError()
                }
                self.activeCaptureSession = session
                if self.captureSessionIntentActive,
                   self.captureSessionIntentGeneration == generation {
                    self.isCaptureSessionActive = true
                }
                return session
            }
        } catch {
            if captureSessionIntentGeneration == generation {
                captureSessionIntentActive = false
                isCaptureSessionActive = false
            }
            throw error
        }
    }

    /// Stops accepting new captures, drains every already accepted ingest, and
    /// only then closes the durable session at its last committed observation.
    func endCaptureSession(reason: CaptureSessionEndReason) async throws {
        // Intent is an immediate coordinator signal. The lifecycle gate only
        // orders repository bodies; a suspended clear must see this stop and
        // refrain from reopening a session.
        captureSessionIntentGeneration += 1
        captureSessionIntentActive = false
        isCaptureSessionActive = false
        invalidateRecoveryFrames()
        try await captureSessionGate.withPermitIgnoringCancellation {
            try await self.endCaptureSessionWithLifecyclePermit(reason: reason)
        }
    }

    private func endCaptureSessionWithLifecyclePermit(
        reason: CaptureSessionEndReason
    ) async throws {
        let repositoryGeneration = repositoryEffectGeneration
        while let ingestProcessorTask {
            await ingestProcessorTask.value
        }
        try await repositoryReconciliationGate.withPermitIgnoringCancellation {
            guard repositoryGeneration == self.repositoryEffectGeneration else { return }
            try await self.retryPendingCaptureSessionCloseIfNeeded(
                repositoryGeneration: repositoryGeneration
            )
            guard repositoryGeneration == self.repositoryEffectGeneration else { return }
            guard let session = self.activeCaptureSession else { return }
            do {
                let effects = try await self.frameRepository.endCaptureSession(
                    id: session.id,
                    reason: reason
                )
                guard repositoryGeneration == self.repositoryEffectGeneration else { return }
                await self.applyRepositoryEffects(effects)
                if self.activeCaptureSession?.id == session.id {
                    self.activeCaptureSession = nil
                }
            } catch let failure as DurablePromotionFailure {
                self.captureInstrumentation.recordPersistedJPEG(receipt: failure.writeReceipt)
                self.pendingCaptureSessionClose = PendingCaptureSessionClose(
                    session: session,
                    reason: reason
                )
                throw failure
            } catch {
                self.pendingCaptureSessionClose = PendingCaptureSessionClose(
                    session: session,
                    reason: reason
                )
                throw error
            }
        }
    }

    func clear() async throws {
        try await captureSessionGate.withPermitIgnoringCancellation {
            try await self.clearWithLifecyclePermit()
        }
    }

    private func clearWithLifecyclePermit() async throws {
        let clearIntentGeneration = captureSessionIntentGeneration
        isCaptureSessionActive = false
        invalidateRecoveryFrames()
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
        var repositoryWasCleared = false
        var cleanupFailures: [String] = []
        var captureResumeError: Error?
        do {
            // Clear is the epoch boundary and must not queue behind an
            // uncooperative operation holding the coordinator gate.
            do {
                try await frameRepository.clear()
                repositoryWasCleared = true
            } catch let error as FrameStoreError {
                guard case .clearIncomplete(let paths) = error else { throw error }
                repositoryWasCleared = true
                cleanupFailures.append(contentsOf: paths)
            }
            repositoryEffectGeneration += 1
            activeCaptureSession = nil
            pendingCaptureSessionClose = nil
            do {
                try await resetInMemoryAfterRepositoryClear()
            } catch {
                cleanupFailures.append("OCR cache: \(DiagnosticsLogFormat.describe(error))")
            }
            if captureSessionIntentActive,
               captureSessionIntentGeneration == clearIntentGeneration {
                do {
                    let session = try await frameRepository.beginCaptureSession(at: Date())
                    activeCaptureSession = session
                    if captureSessionIntentActive,
                       captureSessionIntentGeneration == clearIntentGeneration {
                        isCaptureSessionActive = true
                    }
                } catch {
                    captureResumeError = error
                }
            }
        } catch {
            if !repositoryWasCleared {
                if activeCaptureSession != nil,
                   captureSessionIntentActive,
                   captureSessionIntentGeneration == clearIntentGeneration {
                    isCaptureSessionActive = true
                }
                throw error
            }
        }
        if let captureResumeError, !cleanupFailures.isEmpty {
            throw FrameBufferClearError.cleanupIncompleteAndCaptureResumeFailed(
                cleanupFailures,
                DiagnosticsLogFormat.describe(captureResumeError)
            )
        }
        if let captureResumeError {
            throw FrameBufferClearError.captureResumeFailed(
                DiagnosticsLogFormat.describe(captureResumeError)
            )
        }
        if !cleanupFailures.isEmpty {
            throw FrameBufferClearError.cleanupIncomplete(cleanupFailures)
        }
    }

    private func invalidateRecoveryFrames() {
        recoveryFrameGeneration &+= 1
        recoveryFrameTaskSerial &+= 1
        recoveryFrameTask?.cancel()
        recoveryFrameTask = nil
        pendingRecoveryFrames.removeAll(keepingCapacity: false)
    }

    private func resetInMemoryAfterRepositoryClear() async throws {
        captureInstrumentation.reset()
        lastCaptureInstrumentationDiagnosticAt = Date()
        timelineEntries.removeAll()
        timelineOrderBySpanID.removeAll()
        nextTimelineOrder = 0
        durablePhysicalFrameIDs.removeAll()
        lastAcceptedObservation.removeAll()
        frames.removeAll()
        frameLookup.removeAll()
        decodedCacheGeneration += 1
        thumbnailCache.removeAllObjects()
        fullImageCache.removeAllObjects()
        for task in inFlightFullImageLoads.values {
            task.cancel()
        }
        inFlightFullImageLoads.removeAll()
        try await textCache.clear()
    }

    private func recoverCaptureSessionIfNeeded(at startedAt: Date) async throws {
        let generation = captureSessionIntentGeneration
        let repositoryGeneration = repositoryEffectGeneration
        try await repositoryReconciliationGate.withPermitIgnoringCancellation {
            guard self.captureSessionIntentActive,
                  self.captureSessionIntentGeneration == generation,
                  self.repositoryEffectGeneration == repositoryGeneration else {
                throw CancellationError()
            }
            try await self.retryPendingCaptureSessionCloseIfNeeded(
                repositoryGeneration: repositoryGeneration
            )
            guard self.repositoryEffectGeneration == repositoryGeneration else {
                throw CancellationError()
            }
            if self.activeCaptureSession == nil {
                let session = try await self.frameRepository.beginCaptureSession(at: startedAt)
                guard self.repositoryEffectGeneration == repositoryGeneration else {
                    throw CancellationError()
                }
                self.activeCaptureSession = session
            }
            guard self.captureSessionIntentActive,
                  self.captureSessionIntentGeneration == generation else {
                throw CancellationError()
            }
            self.isCaptureSessionActive = true
        }
    }

    private func retryPendingCaptureSessionCloseIfNeeded(
        repositoryGeneration: Int? = nil
    ) async throws {
        if let repositoryGeneration,
           repositoryGeneration != self.repositoryEffectGeneration {
            return
        }
        guard let pendingCaptureSessionClose else { return }
        let effects: FrameRepositoryEffects
        do {
            effects = try await frameRepository.endCaptureSession(
                id: pendingCaptureSessionClose.session.id,
                reason: pendingCaptureSessionClose.reason
            )
        } catch let failure as DurablePromotionFailure {
            captureInstrumentation.recordPersistedJPEG(receipt: failure.writeReceipt)
            throw failure
        }
        if let repositoryGeneration,
           repositoryGeneration != self.repositoryEffectGeneration {
            return
        }
        await applyRepositoryEffects(effects)
        self.pendingCaptureSessionClose = nil
        if activeCaptureSession?.id == pendingCaptureSessionClose.session.id {
            activeCaptureSession = nil
        }
    }

    func durableJPEGPayloadBytes() async -> Int64 {
        await frameRepository.durableJPEGPayloadBytes()
    }

    func storageStatistics() async -> FrameStorageStatistics {
        await frameRepository.storageStatistics()
    }

    /// Performs RAM-only pressure maintenance. The critical path also sheds
    /// decoded and queued in-memory work, but never flushes or prunes disk and
    /// never clears the persisted OCR text cache.
    @discardableResult
    func respondToMemoryPressure(
        _ level: FrameMemoryPressureLevel
    ) async -> FrameRepositoryMaintenanceResult {
        guard !isMemoryPressureMaintenanceActive else { return .noOp }
        isMemoryPressureMaintenanceActive = true
        defer { isMemoryPressureMaintenanceActive = false }

        while let ingestProcessorTask {
            await ingestProcessorTask.value
        }
        let repositoryGeneration = repositoryEffectGeneration
        let result = await repositoryReconciliationGate.withPermitIgnoringCancellation {
            guard repositoryGeneration == self.repositoryEffectGeneration else {
                return FrameRepositoryMaintenanceResult.noOp
            }
            let result = await self.frameRepository.respondToMemoryPressure(level)
            guard repositoryGeneration == self.repositoryEffectGeneration else { return result }
            await self.applyRepositoryMaintenance(result)
            return result
        }
        guard level == .critical else { return result }

        cancelBackgroundOCRIndexing(clearQueue: true)
        decodedCacheGeneration += 1
        thumbnailCache.removeAllObjects()
        fullImageCache.removeAllObjects()
        for task in inFlightFullImageLoads.values {
            task.cancel()
        }
        inFlightFullImageLoads.removeAll()
        return result
    }

    /// Capture/persistence measurements for the staged storage redesign. This
    /// is intentionally read-only and does not change frame handling.
    func captureInstrumentationSnapshot() -> CapturePersistenceInstrumentationSnapshot {
        captureInstrumentation.currentSnapshot()
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
        do {
            let repositoryGeneration = repositoryEffectGeneration
            try await repositoryReconciliationGate.withPermitIgnoringCancellation {
                guard repositoryGeneration == self.repositoryEffectGeneration else { return }
                try await self.retryPendingCaptureSessionCloseIfNeeded(
                    repositoryGeneration: repositoryGeneration
                )
            }
        } catch {
            let detail = DiagnosticsLogFormat.describe(error)
            captureLogger.error("Failed to retry capture history close while flushing: \(detail, privacy: .public)")
            DiagnosticsLog.shared.log("Capture", "Failed to retry capture history close while flushing: \(detail)")
        }
        await frameRepository.flush()
        maybeLogCaptureInstrumentation(force: true)
    }

    // MARK: - Private

    private func loadPersistedFrames() async {
        timelineEntries = await frameRepository.orderedTimeline()
        timelineOrderBySpanID = Dictionary(
            uniqueKeysWithValues: timelineEntries.enumerated().map { ($0.element.span.id, $0.offset) }
        )
        nextTimelineOrder = timelineEntries.count
        durablePhysicalFrameIDs = Set(timelineEntries.map(\.frame.id))
        sortTimelineEntries()
        rebuildBrowsingProjection()
        rebuildAcceptedObservationBaselines()

        // OCR is still keyed by the physical payload. Refresh only its recency
        // metadata from logical spans; no image decode or recognition occurs.
        var latestObservationByFrameID: [UUID: Date] = [:]
        for entry in timelineEntries {
            let timestamp = timelineSpanBounds(for: entry).end
            if timestamp > (latestObservationByFrameID[entry.frame.id] ?? .distantPast) {
                latestObservationByFrameID[entry.frame.id] = timestamp
            }
        }
        for (frameID, timestamp) in latestObservationByFrameID {
            await textCache.updateTimestamp(for: frameID, timestamp: timestamp)
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

    private func loadFullImage(for frame: StoredFrame) async throws -> CGImage {
        let key = frame.id as NSUUID
        if let cached = fullImageCache.object(forKey: key) {
            return cached
        }

        if let inFlight = inFlightFullImageLoads[frame.id] {
            return try await inFlight.value
        }

        let generation = decodedCacheGeneration
        let repository = frameRepository
        let loadTask = Task(priority: .userInitiated) {
            try await repository.loadFullImage(id: frame.id)
        }
        inFlightFullImageLoads[frame.id] = loadTask

        do {
            let image = try await loadTask.value
            if generation == decodedCacheGeneration, frameLookup[frame.id] != nil {
                fullImageCache.setObject(image, forKey: key, cost: Self.byteCost(of: image))
            }
            if generation == decodedCacheGeneration {
                inFlightFullImageLoads.removeValue(forKey: frame.id)
            }
            return image
        } catch {
            if generation == decodedCacheGeneration {
                inFlightFullImageLoads.removeValue(forKey: frame.id)
            }
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
        if isMemoryPressureMaintenanceActive {
            syncContinuation?.resume(returning: .completed)
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
            let droppedAsyncIngests = ingestQueue.reduce(into: 0) { count, pending in
                if pending.syncContinuation == nil {
                    count += 1
                }
            }
            ingestQueue.removeAll { $0.syncContinuation == nil }
            captureInstrumentation.recordDroppedAsyncIngests(
                droppedAsyncIngests,
                reason: .syncPriority
            )
        }

        ingestQueue.append(pending)
        captureInstrumentation.recordPreTrimIngestQueueDepth(ingestQueue.count)
        let droppedForBacklogLimit = trimIngestQueueIfNeeded()
        captureInstrumentation.recordDroppedAsyncIngests(
            droppedForBacklogLimit,
            reason: .backlogLimit
        )
        captureInstrumentation.recordIngestQueueDepth(ingestQueue.count)
        startIngestProcessorIfNeeded()
    }

    /// Drops oldest async-only pending captures until at most `maxIngestBacklog` remain.
    private func trimIngestQueueIfNeeded() -> Int {
        var droppedCount = 0
        while ingestQueue.count > maxIngestBacklog,
              let dropIndex = ingestQueue.firstIndex(where: { $0.syncContinuation == nil }) {
            ingestQueue.remove(at: dropIndex)
            droppedCount += 1
        }
        return droppedCount
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
        guard matchesIngestGeneration(work.generation) else {
            work.syncContinuation?.resume(returning: .retryAfterClear)
            return
        }
        captureInstrumentation.recordPerceptualObservation(
            hash: hash,
            timestamp: work.timestamp,
            displayID: work.displayID
        )
        let result = await persistIngestedFrame(
            cgImage: work.cgImage,
            timestamp: work.timestamp,
            hash: hash,
            displayID: work.displayID,
            displayName: work.displayName,
            ingestGeneration: work.generation
        )
        maybeLogCaptureInstrumentation()
        work.syncContinuation?.resume(returning: result)
    }

    private func maybeLogCaptureInstrumentation(force: Bool = false) {
        guard let diagnosticsLog else { return }

        let now = Date()
        guard force || now.timeIntervalSince(lastCaptureInstrumentationDiagnosticAt) >= Self.captureInstrumentationDiagnosticInterval else {
            return
        }

        lastCaptureInstrumentationDiagnosticAt = now
        diagnosticsLog.log(
            "CaptureMetrics",
            CapturePersistenceInstrumentationDiagnosticsFormat.line(captureInstrumentation.currentSnapshot())
        )
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
        let admissionMode = await frameRepository.captureAdmissionMode()
        guard admissionMode == .hybridEveryCapture
            || shouldStoreFrame(hash: hash, timestamp: timestamp, displayID: displayID) else {
            return .completed
        }
        do {
            let frame = StoredFrame(
                id: UUID(),
                timestamp: timestamp,
                hash: hash,
                displayID: displayID,
                displayName: displayName
            )
            let quality = saveOptions.quality
            guard let jpegData = await jpegEncoder.encode(cgImage, quality: quality) else {
                guard !Task.isCancelled, generation == ingestGeneration else {
                    return .retryAfterClear
                }
                throw FrameStoreError.imageEncodingFailed
            }
            guard !Task.isCancelled, generation == ingestGeneration else {
                return .retryAfterClear
            }
            captureInstrumentation.recordEncodedJPEG(
                jpegData,
                displayID: displayID,
                compareAgainstPersistedBaseline: admissionMode != .hybridEveryCapture
            )
            let repositoryGeneration = repositoryEffectGeneration
            let reconciliationResult = try await repositoryReconciliationGate.withPermitIgnoringCancellation {
                guard generation == self.ingestGeneration,
                      repositoryGeneration == self.repositoryEffectGeneration else {
                    return SyncIngestResult.retryAfterClear
                }
                let saveResult = try await self.frameRepository.recordEncodedCapture(
                    frame,
                    jpegData: jpegData
                )
                guard repositoryGeneration == self.repositoryEffectGeneration else {
                    return SyncIngestResult.retryAfterClear
                }
                if saveResult.effects.persistenceEvents.isEmpty {
                    // Compatibility for injected repositories which still return
                    // the pre-effects shape. Production repositories emit an
                    // explicit event for every accepted operation.
                    self.captureInstrumentation.recordRepositorySaveOutcome(
                        saveResult.outcome,
                        jpegData: jpegData,
                        displayID: displayID
                    )
                    await self.applyRepositoryInvalidation(saveResult.invalidation)
                    switch saveResult.mutation {
                    case .none:
                        break
                    case .inserted(let entry):
                        self.recordTimelineEntry(entry)
                        if saveResult.outcome.disposition == .durableFrame,
                           self.durablePhysicalFrameIDs.insert(entry.frame.id).inserted {
                            self.enqueueFrameForBackgroundOCR(entry.frame)
                        }
                    case .extended(let span):
                        self.recordExtendedSpan(span)
                        if self.durablePhysicalFrameIDs.contains(span.frameID) {
                            await self.textCache.updateTimestamp(
                                for: span.frameID,
                                timestamp: max(span.startedAt, span.observedThroughAt)
                            )
                        }
                    }
                } else {
                    await self.applyRepositoryEffects(
                        saveResult.effects,
                        acceptedJPEGData: admissionMode == .hybridEveryCapture ? jpegData : nil,
                        acceptedDisplayID: displayID
                    )
                }
                self.recordAcceptedObservation(
                    hash: frame.hash,
                    timestamp: frame.timestamp,
                    displayID: frame.displayID
                )
                return SyncIngestResult.completed
            }
            if case .retryAfterClear = reconciliationResult {
                return reconciliationResult
            }
            await pruneIfNeeded()
            return .completed
        } catch is CancellationError {
            return .retryAfterClear
        } catch let failure as DurablePromotionFailure {
            captureInstrumentation.recordPersistedJPEG(receipt: failure.writeReceipt)
            captureLogger.error(
                "Durable promotion will retry: \(failure.underlyingDescription, privacy: .public)"
            )
            return .completed
        } catch {
            captureLogger.error("Failed to save frame: \(error.localizedDescription, privacy: .public)")
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

        let retentionFrames = timelineEntries.map { entry in
            StoredFrame(
                id: entry.span.id,
                timestamp: timelineSpanBounds(for: entry).end,
                hash: entry.frame.hash,
                displayID: entry.span.displayID,
                displayName: entry.span.displayName
            )
        }.sorted { $0.timestamp < $1.timestamp }
        let spanIDsToPrune = retentionManager.framesToPrune(
            frames: retentionFrames,
            currentTime: now
        )
        guard !spanIDsToPrune.isEmpty else { return }

        let candidateFrameIDs = Set(
            timelineEntries.lazy
                .filter { spanIDsToPrune.contains($0.span.id) }
                .map(\.frame.id)
        )
        ocrPruningFrameIDs.formUnion(candidateFrameIDs)
        defer {
            // Physical assets retained by another span may resume OCR. IDs
            // removed from history are harmless to unblock because the
            // membership check remains authoritative.
            ocrPruningFrameIDs.subtract(candidateFrameIDs)
        }

        do {
            let repositoryGeneration = repositoryEffectGeneration
            try await repositoryReconciliationGate.withPermitIgnoringCancellation {
                guard repositoryGeneration == self.repositoryEffectGeneration else { return }
                let invalidation = try await self.frameRepository.pruneSpans(ids: spanIDsToPrune)
                guard repositoryGeneration == self.repositoryEffectGeneration else { return }
                await self.applyRepositoryInvalidation(invalidation)
                let validIDs = Set(self.timelineEntries.map(\.frame.id))
                await self.textCache.prune(keepingFrameIDs: validIDs)
            }
            captureLogger.info("Pruned \(spanIDsToPrune.count, privacy: .public) spans, \(self.frames.count, privacy: .public) remaining")
        } catch {
            captureLogger.error("Failed to prune frames: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func shouldStoreFrame(hash: UInt64, timestamp: Date, displayID: UUID?) -> Bool {
        guard let candidate = lastAcceptedObservation[CaptureDisplayKey(displayID)] else {
            return true
        }
        guard candidate.hash != 0 else { return true }
        let timeSinceLast = timestamp.timeIntervalSince(candidate.timestamp)
        guard timeSinceLast < duplicatePolicy.minimumSpacing else { return true }
        let distance = PerceptualHash.hammingDistance(hash, candidate.hash)
        return distance > duplicatePolicy.hashThreshold
    }

    private func recordTimelineEntry(_ entry: TimelineEntry) {
        if timelineOrderBySpanID[entry.span.id] == nil {
            timelineOrderBySpanID[entry.span.id] = nextTimelineOrder
            nextTimelineOrder += 1
        }
        timelineEntries.append(entry)
        sortTimelineEntries()
        rebuildBrowsingProjection()
    }

    private func recordExtendedSpan(_ span: TimelineSpan) {
        guard let index = timelineEntries.firstIndex(where: { $0.span.id == span.id }) else {
            return
        }
        timelineEntries[index] = TimelineEntry(span: span, frame: timelineEntries[index].frame)
        rebuildBrowsingProjection()
    }

    /// Applies absolute, source-neutral repository effects. A compound save
    /// can upsert more than one span; durable transitions are fenced by a set
    /// so OCR is enqueued once even if an idempotent retry returns the same
    /// canonical entry.
    private func applyRepositoryEffects(
        _ effects: FrameRepositoryEffects,
        acceptedJPEGData: Data? = nil,
        acceptedDisplayID: UUID? = nil
    ) async {
        captureInstrumentation.recordRepositoryEffects(
            effects,
            acceptedJPEGData: acceptedJPEGData,
            acceptedDisplayID: acceptedDisplayID
        )
        await applyRepositoryInvalidation(effects.invalidation)

        var timelineChanged = false
        for entry in effects.timelineUpserts {
            if let index = timelineEntries.firstIndex(where: { $0.span.id == entry.span.id }) {
                timelineEntries[index] = entry
            } else {
                timelineOrderBySpanID[entry.span.id] = nextTimelineOrder
                nextTimelineOrder += 1
                timelineEntries.append(entry)
            }
            timelineChanged = true
        }
        if timelineChanged {
            sortTimelineEntries()
            rebuildBrowsingProjection()
            rebuildAcceptedObservationBaselines()
        }

        var newlyDurableToEnqueue: [StoredFrame] = []
        for entry in effects.newlyDurableEntries {
            if durablePhysicalFrameIDs.insert(entry.frame.id).inserted {
                newlyDurableToEnqueue.append(entry.frame)
            }
        }

        var cacheTimestamps: [UUID: Date] = [:]
        for event in effects.persistenceEvents {
            let frameID: UUID?
            switch event {
            case .durableAnchor(
                reason: _,
                wroteDurableJPEG: _,
                jpegData: _,
                frameID: let id,
                displayID: _,
                metadataByteCount: _
            ), .spanCheckpoint(frameID: let id, metadataByteCount: _):
                frameID = id
            case .volatileAdmission, .exactDuplicate, .pressureDrop:
                frameID = nil
            }
            // These events are repository authority that the payload is now
            // durable. Do not depend on the local durability set already
            // having observed the same compound transition.
            guard let frameID,
                  await textCache.hasCachedRecord(for: frameID) else { continue }
            let timestamp = timelineEntries.lazy
                .filter { $0.frame.id == frameID }
                .map { timelineSpanBounds(for: $0).end }
                .max()
            if let timestamp {
                cacheTimestamps[frameID] = max(cacheTimestamps[frameID] ?? .distantPast, timestamp)
            }
        }
        for (frameID, timestamp) in cacheTimestamps {
            await textCache.updateTimestamp(for: frameID, timestamp: timestamp)
        }
        // The existence reads above must happen before OCR enqueue. Otherwise
        // the worker can win the race, create a row, and make a new anchor
        // perform a redundant timestamp-only transaction.
        for frame in newlyDurableToEnqueue {
            enqueueFrameForBackgroundOCR(frame)
        }
    }

    /// Reconcile a repository-side eviction or prune before exposing its save
    /// mutation to the UI. Logical spans disappear immediately; physical
    /// cache/OCR cleanup waits until the repository proves the final reference
    /// has gone.
    private func applyRepositoryInvalidation(_ invalidation: FrameRepositoryInvalidation) async {
        guard invalidation != .none else { return }

        if !invalidation.spanIDs.isEmpty {
            timelineEntries.removeAll { invalidation.spanIDs.contains($0.span.id) }
            for spanID in invalidation.spanIDs {
                timelineOrderBySpanID.removeValue(forKey: spanID)
            }
            rebuildBrowsingProjection()
            rebuildAcceptedObservationBaselines()
        }

        let finalPhysicalFrameIDs = invalidation.finalPhysicalFrameIDs
        guard !finalPhysicalFrameIDs.isEmpty else { return }
        decodedCacheGeneration += 1
        for task in inFlightFullImageLoads.values {
            task.cancel()
        }
        inFlightFullImageLoads.removeAll()
        // Volatile payloads are never background-indexed. Restrict OCR queue
        // and SQLite cleanup to IDs known durable before this invalidation;
        // timeline membership already fences any launch-scoped direct-search
        // cache row, without turning each RAM eviction into a disk write.
        let durableFinalFrameIDs = finalPhysicalFrameIDs.intersection(durablePhysicalFrameIDs)
        durablePhysicalFrameIDs.subtract(finalPhysicalFrameIDs)
        removeQueuedOCRFrames(ids: durableFinalFrameIDs)
        for id in finalPhysicalFrameIDs {
            thumbnailCache.removeObject(forKey: id as NSUUID)
            fullImageCache.removeObject(forKey: id as NSUUID)
        }
        await textCache.removeText(forFrameIDs: durableFinalFrameIDs)
    }

    private func rebuildBrowsingProjection() {
        frames = timelineEntries
            .sorted {
                let lhsEnd = timelineSpanBounds(for: $0).end
                let rhsEnd = timelineSpanBounds(for: $1).end
                if lhsEnd != rhsEnd {
                    return lhsEnd < rhsEnd
                }
                return persistedOrderPrecedes($0, $1)
            }
            .map(Self.browsingFrame(from:))
        frameLookup.removeAll(keepingCapacity: true)
        for frame in frames {
            frameLookup[frame.id] = frame
        }
    }

    private func sortTimelineEntries() {
        timelineEntries.sort(by: timelineEntryPrecedes)
    }

    private func timelineEntryPrecedes(_ lhs: TimelineEntry, _ rhs: TimelineEntry) -> Bool {
        let lhsStart = timelineSpanBounds(for: lhs).start
        let rhsStart = timelineSpanBounds(for: rhs).start
        if lhsStart != rhsStart {
            return lhsStart < rhsStart
        }
        return persistedOrderPrecedes(lhs, rhs)
    }

    private func persistedOrderPrecedes(_ lhs: TimelineEntry, _ rhs: TimelineEntry) -> Bool {
        return (timelineOrderBySpanID[lhs.span.id] ?? .max)
            < (timelineOrderBySpanID[rhs.span.id] ?? .max)
    }

    private func rebuildAcceptedObservationBaselines() {
        lastAcceptedObservation.removeAll(keepingCapacity: true)
        for entry in timelineEntries {
            recordAcceptedObservation(
                hash: entry.frame.hash,
                timestamp: timelineSpanBounds(for: entry).end,
                displayID: entry.span.displayID
            )
        }
    }

    private func recordAcceptedObservation(hash: UInt64, timestamp: Date, displayID: UUID?) {
        let key = CaptureDisplayKey(displayID)
        guard timestamp >= (lastAcceptedObservation[key]?.timestamp ?? .distantPast) else { return }
        lastAcceptedObservation[key] = AcceptedCaptureObservation(hash: hash, timestamp: timestamp)
    }

    private static func browsingFrame(from entry: TimelineEntry) -> StoredFrame {
        StoredFrame(
            id: entry.frame.id,
            timestamp: timelineSpanBounds(for: entry).end,
            hash: entry.frame.hash,
            displayID: entry.span.displayID,
            displayName: entry.span.displayName ?? entry.frame.displayName
        )
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
        recordQueueDepthTelemetry()
        startBackgroundOCRIndexingIfNeeded()
    }

    private func enqueueStoredFramesForBackgroundOCR() {
        let policy = ocrIndexingPolicy
        let minimumTimestamp = minimumQueuedOCRFrameTimestamp(for: policy)
        var newestPhysicalFrames: [UUID: StoredFrame] = [:]
        for entry in timelineEntries {
            let projected = Self.browsingFrame(from: entry)
            if projected.timestamp >= (newestPhysicalFrames[projected.id]?.timestamp ?? .distantPast) {
                newestPhysicalFrames[projected.id] = projected
            }
        }
        let eligibleFrames: [StoredFrame]
        if let minimumTimestamp {
            eligibleFrames = newestPhysicalFrames.values.filter {
                durablePhysicalFrameIDs.contains($0.id) && $0.timestamp >= minimumTimestamp
            }
        } else {
            eligibleFrames = newestPhysicalFrames.values.filter { durablePhysicalFrameIDs.contains($0.id) }
        }

        ocrFrameQueue.enqueue(contentsOf: eligibleFrames.sorted { $0.timestamp < $1.timestamp })
        applyOCRQueuePolicy(policy)
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

    /// Resolve recency on the main-actor timeline immediately before a cache
    /// write. A later span extension still advances an existing row through
    /// `TextCache.updateTimestamp`, whose update is monotonic.
    private func currentOCRCacheTimestamp(for frame: StoredFrame) -> Date? {
        guard shouldContinueOCR(for: frame) else { return nil }
        return frameLookup[frame.id]?.timestamp
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
