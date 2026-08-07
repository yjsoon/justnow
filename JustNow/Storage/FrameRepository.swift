//
//  FrameRepository.swift
//  JustNow
//

import CoreGraphics
import Foundation

/// Source-neutral frame identity and timeline metadata. Image payloads are
/// resolved lazily through `FrameRepository`, regardless of where a future
/// repository implementation keeps them.
nonisolated struct StoredFrame: Identifiable, Sendable, Equatable {
    let id: UUID
    let timestamp: Date
    let hash: UInt64
    let displayID: UUID?
    let displayName: String?
}

/// Capture admission is deliberately a repository decision. The durable
/// repository keeps the existing cadence/pHash admission in `FrameBuffer`,
/// while the experimental hybrid repository needs every encoded capture to
/// decide exact-byte coalescing against its active payload.
nonisolated enum FrameCaptureAdmissionMode: Sendable, Equatable {
    case diskCadenceFiltered
    case hybridEveryCapture
}

/// Logical and physical removals reported by a repository operation. A span
/// can disappear while its JPEG remains referenced by another span, so OCR and
/// decoded-image caches must only react to `finalPhysicalFrameIDs`.
nonisolated struct FrameRepositoryInvalidation: Sendable, Equatable {
    let spanIDs: Set<UUID>
    let finalPhysicalFrameIDs: Set<UUID>

    static let none = FrameRepositoryInvalidation(spanIDs: [], finalPhysicalFrameIDs: [])
}

nonisolated enum FrameMemoryPressureLevel: Sendable, Equatable {
    case warning
    case critical
}

/// Aggregate source resolution counters. They identify where payloads were
/// read, not filesystems or physical NAND writes.
nonisolated struct FramePayloadResolutionStatistics: Sendable, Equatable {
    let volatilePayloadResolutions: Int
    let durablePayloadResolutions: Int

    static let empty = FramePayloadResolutionStatistics(
        volatilePayloadResolutions: 0,
        durablePayloadResolutions: 0
    )
}

/// Holds volatile payloads stable while a consumer such as the overlay is
/// presenting them. Releasing a lease never permits the ring to exceed its
/// configured byte cap.
nonisolated protocol FrameRepositoryPayloadLease: AnyObject, Sendable {
    /// Releasing the last pin can complete a warning-time deferred trim. The
    /// caller must apply the returned source-neutral effects before resuming a
    /// consumer which was paused behind this lease.
    func release() async -> FrameRepositoryMaintenanceResult
}

nonisolated final class NoopFrameRepositoryPayloadLease: FrameRepositoryPayloadLease, @unchecked Sendable {
    func release() async -> FrameRepositoryMaintenanceResult { .noOp }
}

/// One repository timeline snapshot and the lease that pins every volatile
/// payload referenced by that exact snapshot. Callers must retain the lease
/// for as long as they may resolve any entry in `entries`.
nonisolated struct FrameRepositoryLeasedTimelineSnapshot: Sendable {
    let entries: [TimelineEntry]
    let lease: any FrameRepositoryPayloadLease
}

/// Launch-scoped storage choice. A running `FrameBuffer` never changes source
/// in place; Settings compares this effective value with the saved next-launch
/// preference instead.
nonisolated enum HistoryStorageMode: Sendable, Equatable {
    case allDisk
    case hybridRAM(byteCap: Int)

    static let defaultHybridByteCap = 512 * 1024 * 1024

    static func launchDefault(defaults: UserDefaults = .standard) -> Self {
        guard defaults.bool(forKey: AppStorageKey.reducedDiskWritesEnabled) else {
            return .allDisk
        }
        let limit = RecentDetailMemoryLimit.resolved(
            from: defaults.integer(forKey: AppStorageKey.recentDetailMemoryMiB)
        )
        return .hybridRAM(byteCap: limit.byteCount)
    }
}

/// Describes what a repository did for one accepted save request. The
/// disposition is intentionally source-neutral so a future hybrid repository
/// can report volatile frames, duplicate coalescing, and checkpoint writes
/// without teaching `FrameBuffer` about its storage layout.
nonisolated struct FrameRepositorySaveOutcome: Sendable, Equatable {
    enum Disposition: Sendable, Equatable {
        case durableFrame
        case volatileFrame
        case duplicateFrame
        case spanCheckpoint
        case pressureDrop
    }

    let disposition: Disposition
    /// True only when this request wrote the supplied JPEG durably.
    let wroteDurableJPEG: Bool
    /// One entry per durable metadata transaction, expressed as its logical
    /// payload size. An array keeps future compound/checkpoint writes visible.
    let metadataWriteByteCounts: [Int]

    static func durableFrame(
        wroteDurableJPEG: Bool = true,
        metadataByteCount: Int
    ) -> Self {
        Self(
            disposition: .durableFrame,
            wroteDurableJPEG: wroteDurableJPEG,
            metadataWriteByteCounts: metadataByteCount > 0 ? [metadataByteCount] : []
        )
    }

    static let volatileFrame = Self(
        disposition: .volatileFrame,
        wroteDurableJPEG: false,
        metadataWriteByteCounts: []
    )

    static let duplicateFrame = Self(
        disposition: .duplicateFrame,
        wroteDurableJPEG: false,
        metadataWriteByteCounts: []
    )

    static func spanCheckpoint(metadataByteCount: Int) -> Self {
        Self(
            disposition: .spanCheckpoint,
            wroteDurableJPEG: false,
            metadataWriteByteCounts: metadataByteCount > 0 ? [metadataByteCount] : []
        )
    }

    static let pressureDrop = Self(
        disposition: .pressureDrop,
        wroteDurableJPEG: false,
        metadataWriteByteCounts: []
    )
}

/// Why one physical JPEG became durable. Hybrid history uses the first five
/// cases; `allDisk` preserves the existing repository path without pretending
/// that its older admission policy made a hybrid anchor decision.
nonisolated enum FrameRepositoryDurableAnchorReason: Sendable, Equatable {
    case firstInSession
    case ordinary
    case majorChange
    case capacitySpill
    case termination
    case allDisk
}

/// One logical persistence observation. A capture can emit more than one
/// event, such as an exact duplicate which also promotes or checkpoints its
/// accumulated span.
nonisolated enum FrameRepositoryPersistenceEvent: Sendable, Equatable {
    case volatileAdmission
    case exactDuplicate
    case pressureDrop
    case durableAnchor(
        reason: FrameRepositoryDurableAnchorReason,
        wroteDurableJPEG: Bool,
        jpegData: Data?,
        frameID: UUID,
        displayID: UUID?,
        metadataByteCount: Int
    )
    case spanCheckpoint(frameID: UUID, metadataByteCount: Int)
}

/// Source-neutral changes which callers apply atomically to their in-memory
/// projections. Timeline values are absolute upserts keyed by span ID; they
/// are never deltas whose observation count could be replayed twice.
nonisolated struct FrameRepositoryEffects: Sendable, Equatable {
    var timelineUpserts: [TimelineEntry]
    var invalidation: FrameRepositoryInvalidation
    var newlyDurableEntries: [TimelineEntry]
    var persistenceEvents: [FrameRepositoryPersistenceEvent]

    static let empty = Self(
        timelineUpserts: [],
        invalidation: .none,
        newlyDurableEntries: [],
        persistenceEvents: []
    )

    mutating func merge(_ other: Self) {
        timelineUpserts.append(contentsOf: other.timelineUpserts)
        invalidation = FrameRepositoryInvalidation(
            spanIDs: invalidation.spanIDs.union(other.invalidation.spanIDs),
            finalPhysicalFrameIDs: invalidation.finalPhysicalFrameIDs
                .union(other.invalidation.finalPhysicalFrameIDs)
        )
        newlyDurableEntries.append(contentsOf: other.newlyDurableEntries)
        persistenceEvents.append(contentsOf: other.persistenceEvents)
    }
}

/// Result of RAM-only repository maintenance. `effects` reconciles the
/// caller's timeline and decoded caches; the byte values make partial trims
/// caused by active leases explicit.
nonisolated struct FrameRepositoryMaintenanceResult: Sendable, Equatable {
    let effects: FrameRepositoryEffects
    let bytesBefore: Int64
    let bytesAfter: Int64
    let targetBytes: Int64

    var invalidation: FrameRepositoryInvalidation { effects.invalidation }
    var residualBytes: Int64 { max(0, bytesAfter - targetBytes) }

    static let noOp = Self(
        effects: .empty,
        bytesBefore: 0,
        bytesAfter: 0,
        targetBytes: 0
    )
}

nonisolated enum FrameRepositoryMutation: Sendable, Equatable {
    case none
    case inserted(TimelineEntry)
    case extended(TimelineSpan)
}

nonisolated struct FrameRepositorySaveResult: Sendable, Equatable {
    let mutation: FrameRepositoryMutation
    let outcome: FrameRepositorySaveOutcome
    let effects: FrameRepositoryEffects

    var invalidation: FrameRepositoryInvalidation { effects.invalidation }

    init(
        mutation: FrameRepositoryMutation,
        outcome: FrameRepositorySaveOutcome,
        invalidation: FrameRepositoryInvalidation = .none,
        effects: FrameRepositoryEffects? = nil
    ) {
        self.mutation = mutation
        self.outcome = outcome
        if let effects {
            self.effects = effects
        } else {
            let upserts: [TimelineEntry]
            let newlyDurable: [TimelineEntry]
            switch mutation {
            case .none:
                upserts = []
                newlyDurable = []
            case .inserted(let entry):
                upserts = [entry]
                newlyDurable = outcome.disposition == .durableFrame ? [entry] : []
            case .extended:
                upserts = []
                newlyDurable = []
            }
            self.effects = FrameRepositoryEffects(
                timelineUpserts: upserts,
                invalidation: invalidation,
                newlyDurableEntries: newlyDurable,
                persistenceEvents: []
            )
        }
    }
}

/// The durable metadata effect produced by one promotion/checkpoint call.
/// `reconciledCommitted` means SQLite reported an error after COMMIT, but a
/// direct canonical lookup proved that the requested absolute state committed.
nonisolated enum DurablePersistenceEffect: Sendable, Equatable {
    case inserted
    case checkpointed
    case noOp
    case reconciledCommitted
}

/// Canonical durable state after a promotion/checkpoint attempt. The effect
/// and byte counts describe this call only: idempotent retries return `noOp`
/// with zero writes, while an ambiguous committed call is surfaced once as
/// `reconciledCommitted` with the write counts of the proven commit.
nonisolated struct DurablePersistenceResult: Sendable, Equatable {
    let effect: DurablePersistenceEffect
    let entry: TimelineEntry
    let wroteDurableJPEG: Bool
    let logicalMetadataByteCount: Int
}

/// A count-once receipt for a JPEG that reached durable storage even though
/// its promotion call failed before it could return a persistence result.
/// The retry reuses the owned payload and therefore never emits this receipt
/// again. Keeping the exact bytes lets the single instrumentation owner update
/// both byte totals and its exact-comparison baseline.
nonisolated struct DurableJPEGWriteReceipt: Sendable, Equatable {
    /// Unique to the physical absent-to-present JPEG write. Copies of a
    /// receipt retain this token so instrumentation can reject replay.
    let writeToken: UUID
    let frameID: UUID
    let jpegData: Data
    let displayID: UUID?

    var byteCount: Int { jpegData.count }
}

/// Typed failure for a promotion call that retained a newly written JPEG but
/// did not produce a successful metadata result. Callers consume
/// `writeReceipt` once, then may retry the same absolute promotion safely.
nonisolated struct DurablePromotionFailure: Error, Sendable, Equatable {
    let writeReceipt: DurableJPEGWriteReceipt
    let underlyingDescription: String
}

/// Test-only transaction boundary classification used by FrameStore's fault
/// seam. Production callers do not install a hook.
nonisolated enum DurablePersistenceOperation: Sendable, Equatable {
    case promotion
    case checkpoint
}

/// The sole image-storage seam used by capture, browsing, OCR, and export.
/// Today every frame is delegated to `FrameStore`; a later implementation can
/// combine durable and volatile sources without exposing that distinction to
/// callers.
nonisolated protocol FrameRepository: Sendable {
    func captureAdmissionMode() async -> FrameCaptureAdmissionMode
    func cleanupOrphans() async throws
    func orderedFrames() async -> [StoredFrame]
    func orderedTimeline() async -> [TimelineEntry]
    func beginCaptureSession(at startedAt: Date) async throws -> CaptureSession
    func endCaptureSession(
        id: UUID,
        reason: CaptureSessionEndReason
    ) async throws -> FrameRepositoryEffects
    func recordEncodedCapture(
        _ frame: StoredFrame,
        jpegData: Data
    ) async throws -> FrameRepositorySaveResult

    func loadFullImage(id: UUID) async throws -> CGImage
    func loadThumbnail(id: UUID) async -> CGImage?
    func loadSearchIndexImage(id: UUID, maxPixelSize: Int) async throws -> CGImage
    func exportFrame(id: UUID, timestamp: Date) async throws -> URL
    func exportCroppedImage(_ image: CGImage, timestamp: Date) async throws -> URL
    func acquirePayloadLease(for physicalFrameIDs: Set<UUID>) async -> any FrameRepositoryPayloadLease
    func acquireCurrentTimelineSnapshotLease() async -> FrameRepositoryLeasedTimelineSnapshot
    func payloadResolutionStatistics() async -> FramePayloadResolutionStatistics
    func respondToMemoryPressure(
        _ level: FrameMemoryPressureLevel
    ) async -> FrameRepositoryMaintenanceResult

    /// Deletes logical spans and reports only payload IDs whose final
    /// reference was removed.
    func pruneSpans(ids: Set<UUID>) async throws -> FrameRepositoryInvalidation
    func clear() async throws
    func durableJPEGPayloadBytes() async -> Int64
    func storageStatistics() async -> FrameStorageStatistics
    func flush() async
}

extension FrameRepository {
    func captureAdmissionMode() async -> FrameCaptureAdmissionMode {
        .diskCadenceFiltered
    }

    func acquirePayloadLease(for physicalFrameIDs: Set<UUID>) async -> any FrameRepositoryPayloadLease {
        NoopFrameRepositoryPayloadLease()
    }

    func acquireCurrentTimelineSnapshotLease() async -> FrameRepositoryLeasedTimelineSnapshot {
        let entries = await orderedTimeline()
        let lease = await acquirePayloadLease(for: Set(entries.map(\.frame.id)))
        return FrameRepositoryLeasedTimelineSnapshot(entries: entries, lease: lease)
    }

    func payloadResolutionStatistics() async -> FramePayloadResolutionStatistics {
        .empty
    }

    func respondToMemoryPressure(
        _ level: FrameMemoryPressureLevel
    ) async -> FrameRepositoryMaintenanceResult {
        .noOp
    }
}

/// Durable operations needed by the hybrid repository in addition to the
/// source-neutral contract. Keeping this injectable makes durable failures and
/// suspended exact comparisons deterministic in repository tests.
nonisolated protocol HybridDurableRepository: FrameRepository {
    func durableStorageSnapshot(
        logicalOverlay: [TimelineEntry]
    ) async -> DurableFrameStorageSnapshot
    func recordEncodedCapture(
        _ frame: StoredFrame,
        jpegData: Data,
        forceNewSpan: Bool
    ) async throws -> FrameRepositorySaveResult
    func encodedPayload(id: UUID) async throws -> Data
    func exportEncodedPayload(_ data: Data, timestamp: Date) async throws -> URL
    func promoteVolatileEntry(
        _ entry: TimelineEntry,
        jpegData: Data
    ) async throws -> DurablePersistenceResult
    func checkpointPromotedSpan(_ span: TimelineSpan) async throws -> DurablePersistenceResult
    func durableEntry(frameID: UUID, spanID: UUID) async throws -> TimelineEntry?
}

/// Current repository implementation. It intentionally remains all-durable:
/// every encoded capture is written to the existing SQLite-backed frame store.
nonisolated final class DiskFrameRepository: HybridDurableRepository, Sendable {
    private let frameStore: FrameStore

    init(frameStore: FrameStore) {
        self.frameStore = frameStore
    }

    func captureAdmissionMode() async -> FrameCaptureAdmissionMode {
        .diskCadenceFiltered
    }

    func cleanupOrphans() async throws {
        try await frameStore.cleanupOrphans()
    }

    func orderedFrames() async -> [StoredFrame] {
        await frameStore.getAllMetadata().map(Self.storedFrame(from:))
    }

    func orderedTimeline() async -> [TimelineEntry] {
        await frameStore.getTimelineEntries()
    }

    func beginCaptureSession(at startedAt: Date) async throws -> CaptureSession {
        try await frameStore.beginCaptureSession(at: startedAt)
    }

    func endCaptureSession(
        id: UUID,
        reason: CaptureSessionEndReason
    ) async throws -> FrameRepositoryEffects {
        try await frameStore.endCaptureSession(id: id, reason: reason)
        return .empty
    }

    func recordEncodedCapture(
        _ frame: StoredFrame,
        jpegData: Data
    ) async throws -> FrameRepositorySaveResult {
        try await recordEncodedCapture(frame, jpegData: jpegData, forceNewSpan: false)
    }

    func promoteVolatileEntry(
        _ entry: TimelineEntry,
        jpegData: Data
    ) async throws -> DurablePersistenceResult {
        try await frameStore.promoteVolatileEntry(entry, jpegData: jpegData)
    }

    func checkpointPromotedSpan(_ span: TimelineSpan) async throws -> DurablePersistenceResult {
        try await frameStore.checkpointPromotedSpan(span)
    }

    func durableEntry(frameID: UUID, spanID: UUID) async throws -> TimelineEntry? {
        try await frameStore.durableEntry(frameID: frameID, spanID: spanID)
    }

    /// Hybrid mode uses this narrowly scoped escape hatch after a volatile
    /// capture. The disk store must then start a fresh durable span rather
    /// than accidentally extending an older, no-longer-adjacent payload.
    func recordEncodedCapture(
        _ frame: StoredFrame,
        jpegData: Data,
        forceNewSpan: Bool
    ) async throws -> FrameRepositorySaveResult {
        let mutation = try await frameStore.recordEncodedCapture(
            frame: frame,
            jpegData: jpegData,
            forceNewSpan: forceNewSpan
        )
        switch mutation {
        case .inserted(let entry):
            let metadataByteCount = FrameDatabase.logicalByteCount(for: entry)
            return FrameRepositorySaveResult(
                mutation: .inserted(entry),
                outcome: .durableFrame(
                    metadataByteCount: metadataByteCount
                ),
                effects: FrameRepositoryEffects(
                    timelineUpserts: [entry],
                    invalidation: .none,
                    newlyDurableEntries: [entry],
                    persistenceEvents: [
                        .durableAnchor(
                            reason: .allDisk,
                            wroteDurableJPEG: true,
                            jpegData: jpegData,
                            frameID: entry.frame.id,
                            displayID: frame.displayID,
                            metadataByteCount: metadataByteCount
                        )
                    ]
                )
            )
        case .extended(let span):
            guard let entry = try await frameStore.durableEntry(
                frameID: span.frameID,
                spanID: span.id
            ) else {
                throw FrameStoreError.database("Extended durable span disappeared")
            }
            let metadataByteCount = FrameDatabase.logicalByteCount(for: span)
            return FrameRepositorySaveResult(
                mutation: .extended(span),
                outcome: .spanCheckpoint(
                    metadataByteCount: metadataByteCount
                ),
                effects: FrameRepositoryEffects(
                    timelineUpserts: [entry],
                    invalidation: .none,
                    newlyDurableEntries: [],
                    persistenceEvents: [
                        .spanCheckpoint(frameID: span.frameID, metadataByteCount: metadataByteCount)
                    ]
                )
            )
        }
    }

    func loadFullImage(id: UUID) async throws -> CGImage {
        try await frameStore.loadFullImage(id: id)
    }

    func loadThumbnail(id: UUID) async -> CGImage? {
        await frameStore.loadThumbnail(id: id)
    }

    func loadSearchIndexImage(id: UUID, maxPixelSize: Int) async throws -> CGImage {
        try await frameStore.loadSearchIndexImage(id: id, maxPixelSize: maxPixelSize)
    }

    func exportFrame(id: UUID, timestamp: Date) async throws -> URL {
        try await frameStore.copyFrameToScreenshotsLocation(id: id, timestamp: timestamp)
    }

    func exportCroppedImage(_ image: CGImage, timestamp: Date) async throws -> URL {
        try await frameStore.saveCroppedImageToScreenshotsLocation(image: image, timestamp: timestamp)
    }

    func acquirePayloadLease(for physicalFrameIDs: Set<UUID>) async -> any FrameRepositoryPayloadLease {
        NoopFrameRepositoryPayloadLease()
    }

    func payloadResolutionStatistics() async -> FramePayloadResolutionStatistics {
        .empty
    }

    func pruneSpans(ids: Set<UUID>) async throws -> FrameRepositoryInvalidation {
        FrameRepositoryInvalidation(
            spanIDs: ids,
            finalPhysicalFrameIDs: try await frameStore.pruneSpans(ids: ids)
        )
    }

    func clear() async throws {
        try await frameStore.clear()
    }

    func durableJPEGPayloadBytes() async -> Int64 {
        await frameStore.durableJPEGPayloadBytes()
    }

    func storageStatistics() async -> FrameStorageStatistics {
        await frameStore.storageStatistics()
    }

    func durableStorageSnapshot(
        logicalOverlay: [TimelineEntry]
    ) async -> DurableFrameStorageSnapshot {
        await frameStore.storageSnapshot(logicalOverlay: logicalOverlay)
    }

    func flush() async {
        await frameStore.flush()
    }

    func encodedPayload(id: UUID) async throws -> Data {
        try await frameStore.encodedPayload(id: id)
    }

    func exportEncodedPayload(_ data: Data, timestamp: Date) async throws -> URL {
        try await frameStore.saveEncodedFrameToScreenshotsLocation(data, timestamp: timestamp)
    }

    private static func storedFrame(from metadata: FrameMetadata) -> StoredFrame {
        StoredFrame(
            id: metadata.id,
            timestamp: metadata.timestamp,
            hash: metadata.hash,
            displayID: metadata.displayID,
            displayName: metadata.displayName
        )
    }
}
