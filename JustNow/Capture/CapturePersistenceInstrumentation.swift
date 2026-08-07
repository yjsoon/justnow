//
//  CapturePersistenceInstrumentation.swift
//  JustNow
//

import Foundation

/// Minimal diagnostics dependency for aggregate capture/storage metrics.
/// Implementations receive no images, text, file paths, display names, IDs,
/// or perceptual hashes.
protocol CaptureInstrumentationLogSink: AnyObject {
    func log(_ category: String, _ message: String)
}

extension DiagnosticsLog: CaptureInstrumentationLogSink {}

/// The future durable-history policy is measured here only. It deliberately
/// does not participate in dedupe, persistence, retention, OCR, or UI
/// decisions while the storage redesign is being validated.
nonisolated struct ShadowAnchorPolicy: Sendable, Equatable {
    let ordinaryInterval: TimeInterval
    let majorChangeHammingDistance: Int
    let majorChangeMinimumSpacing: TimeInterval

    static let standard = ShadowAnchorPolicy(
        ordinaryInterval: 5,
        majorChangeHammingDistance: 12,
        majorChangeMinimumSpacing: 1
    )
}

/// A cheap, point-in-time view of capture and persistence work. All byte
/// figures are logical payload bytes reported by the app, not filesystem or
/// NAND-write measurements.
nonisolated struct CapturePersistenceInstrumentationSnapshot: Sendable, Equatable {
    /// Starts at zero and advances only after a successful Clear All History.
    let epoch: Int
    let capturedFrames: Int
    let encodedFrames: Int
    let persistedFrames: Int
    /// Encoded JPEGs small enough for a byte-for-byte comparison.
    let exactComparisonEligibleFrames: Int
    /// Eligible JPEGs with the preceding same-display comparison baseline.
    /// Hybrid mode uses the repository's active accepted payload; all-disk
    /// compatibility instrumentation uses the last durable payload.
    let exactComparisonBaselineAvailableFrames: Int
    /// Encoded JPEGs over the bounded observer comparison budget.
    let exactComparisonSkippedFrames: Int
    /// Exact-duplicate decisions reported by the active repository policy.
    let repositoryExactDuplicateFrames: Int
    let perceptuallyEqualFrames: Int
    /// Sum of JPEG payload sizes for durable-write events. This is logical
    /// event volume, not allocated-space growth or physical/NAND writes.
    let logicalDurableJPEGEventBytes: Int64
    /// Estimated logical metadata payload represented by transactions.
    let logicalMetadataEventBytes: Int64
    let metadataTransactions: Int
    let durableRepositorySaves: Int
    let volatileRepositorySaves: Int
    let duplicateRepositorySaves: Int
    let spanCheckpointRepositorySaves: Int
    let pressureDroppedRepositorySaves: Int
    let firstAnchorRepositorySaves: Int
    let ordinaryAnchorRepositorySaves: Int
    let majorChangeAnchorRepositorySaves: Int
    let capacitySpillRepositorySaves: Int
    let terminationAnchorRepositorySaves: Int
    let proposedOrdinaryAnchors: Int
    let proposedMajorAnchors: Int
    /// Peak queue length immediately after enqueue and before dropping work.
    let maximumPreTrimIngestQueueDepth: Int
    let maximumIngestQueueDepth: Int
    let droppedAsyncIngests: Int
    let droppedAsyncIngestsForSyncPriority: Int
    let droppedAsyncIngestsForBacklogLimit: Int
    let largestEncodedJPEGBytes: Int
    let largestMetadataWriteBytes: Int
    /// The display tracker is intentionally capped; this is its high-water
    /// mark, rather than a process-lifetime count of every hot-plugged UUID.
    let maximumObservedDisplays: Int
    let currentTrackedDisplays: Int
    let displayStateEvictions: Int

    static let empty = CapturePersistenceInstrumentationSnapshot(
        epoch: 0,
        capturedFrames: 0,
        encodedFrames: 0,
        persistedFrames: 0,
        exactComparisonEligibleFrames: 0,
        exactComparisonBaselineAvailableFrames: 0,
        exactComparisonSkippedFrames: 0,
        repositoryExactDuplicateFrames: 0,
        perceptuallyEqualFrames: 0,
        logicalDurableJPEGEventBytes: 0,
        logicalMetadataEventBytes: 0,
        metadataTransactions: 0,
        durableRepositorySaves: 0,
        volatileRepositorySaves: 0,
        duplicateRepositorySaves: 0,
        spanCheckpointRepositorySaves: 0,
        pressureDroppedRepositorySaves: 0,
        firstAnchorRepositorySaves: 0,
        ordinaryAnchorRepositorySaves: 0,
        majorChangeAnchorRepositorySaves: 0,
        capacitySpillRepositorySaves: 0,
        terminationAnchorRepositorySaves: 0,
        proposedOrdinaryAnchors: 0,
        proposedMajorAnchors: 0,
        maximumPreTrimIngestQueueDepth: 0,
        maximumIngestQueueDepth: 0,
        droppedAsyncIngests: 0,
        droppedAsyncIngestsForSyncPriority: 0,
        droppedAsyncIngestsForBacklogLimit: 0,
        largestEncodedJPEGBytes: 0,
        largestMetadataWriteBytes: 0,
        maximumObservedDisplays: 0,
        currentTrackedDisplays: 0,
        displayStateEvictions: 0
    )
}

/// Produces a compact diagnostics line containing only aggregate counts and
/// byte totals: no capture content, paths, display names, IDs, or hashes.
enum CapturePersistenceInstrumentationDiagnosticsFormat {
    static func line(_ snapshot: CapturePersistenceInstrumentationSnapshot) -> String {
        "epoch=\(snapshot.epoch) captured=\(snapshot.capturedFrames) encoded=\(snapshot.encodedFrames) durableJPEGEvents=\(snapshot.persistedFrames) repository{durable=\(snapshot.durableRepositorySaves) volatile=\(snapshot.volatileRepositorySaves) duplicate=\(snapshot.duplicateRepositorySaves) checkpoint=\(snapshot.spanCheckpointRepositorySaves) pressureDropped=\(snapshot.pressureDroppedRepositorySaves)} actualAnchors{first=\(snapshot.firstAnchorRepositorySaves) ordinary=\(snapshot.ordinaryAnchorRepositorySaves) major=\(snapshot.majorChangeAnchorRepositorySaves) capacity=\(snapshot.capacitySpillRepositorySaves) termination=\(snapshot.terminationAnchorRepositorySaves)} exact{eligible=\(snapshot.exactComparisonEligibleFrames) baseline=\(snapshot.exactComparisonBaselineAvailableFrames) repositoryDuplicate=\(snapshot.repositoryExactDuplicateFrames) skipped=\(snapshot.exactComparisonSkippedFrames)} perceptualEqual=\(snapshot.perceptuallyEqualFrames) logicalJPEGEventBytes=\(snapshot.logicalDurableJPEGEventBytes) logicalMetadata{eventBytes=\(snapshot.logicalMetadataEventBytes) transactions=\(snapshot.metadataTransactions)} proposedAnchors{ordinary=\(snapshot.proposedOrdinaryAnchors) major=\(snapshot.proposedMajorAnchors)} queue{preTrimHigh=\(snapshot.maximumPreTrimIngestQueueDepth) retainedHigh=\(snapshot.maximumIngestQueueDepth) asyncDropped=\(snapshot.droppedAsyncIngests) priorityDropped=\(snapshot.droppedAsyncIngestsForSyncPriority) backlogDropped=\(snapshot.droppedAsyncIngestsForBacklogLimit)} displays{current=\(snapshot.currentTrackedDisplays) high=\(snapshot.maximumObservedDisplays) evictions=\(snapshot.displayStateEvictions)} payloadHigh{jpeg=\(snapshot.largestEncodedJPEGBytes) metadata=\(snapshot.largestMetadataWriteBytes)}"
    }
}

/// Thread-safe observer shared by the main-actor buffer and frame-store actor.
/// Its bounded baselines exist only for diagnostic comparisons; hybrid exact
/// duplicate totals come from repository decisions.
nonisolated final class CapturePersistenceInstrumentation: @unchecked Sendable {
    private struct DisplayObservation {
        var lastHash: UInt64?
        var lastProposedAnchor: Date?
        var lastProposedMajorAnchor: Date?
    }

    private let lock = NSLock()
    private let shadowAnchorPolicy: ShadowAnchorPolicy
    static let maximumComparableJPEGBytes = 2 * 1024 * 1024
    static let maximumTrackedDisplays = 8
    private var snapshot = CapturePersistenceInstrumentationSnapshot.empty
    private var observations: [UUID?: DisplayObservation] = [:]
    private var lastPersistedJPEGData: [UUID?: Data] = [:]
    private var lastAcceptedJPEGData: [UUID?: Data] = [:]
    private var trackedDisplayOrder: [UUID?] = []
    private var recordedWriteReceiptTokens: Set<UUID> = []

    init(shadowAnchorPolicy: ShadowAnchorPolicy = .standard) {
        self.shadowAnchorPolicy = shadowAnchorPolicy
    }

    func recordCapturedFrame(displayID: UUID?) {
        withLock {
            snapshot = snapshot.replacing(capturedFrames: snapshot.capturedFrames + 1)
            touchDisplay(displayID)
        }
    }

    /// Captures the transient queue pressure before the buffer deliberately
    /// sheds older asynchronous work.
    func recordPreTrimIngestQueueDepth(_ depth: Int) {
        withLock {
            snapshot = snapshot.replacing(
                maximumPreTrimIngestQueueDepth: max(snapshot.maximumPreTrimIngestQueueDepth, depth)
            )
        }
    }

    func recordIngestQueueDepth(_ depth: Int) {
        withLock {
            snapshot = snapshot.replacing(
                maximumIngestQueueDepth: max(snapshot.maximumIngestQueueDepth, depth)
            )
        }
    }

    func recordDroppedAsyncIngests(_ count: Int, reason: AsyncIngestDropReason) {
        guard count > 0 else { return }
        withLock {
            var next = snapshot.replacing(droppedAsyncIngests: snapshot.droppedAsyncIngests + count)
            switch reason {
            case .syncPriority:
                next = next.replacing(
                    droppedAsyncIngestsForSyncPriority: next.droppedAsyncIngestsForSyncPriority + count
                )
            case .backlogLimit:
                next = next.replacing(
                    droppedAsyncIngestsForBacklogLimit: next.droppedAsyncIngestsForBacklogLimit + count
                )
            }
            snapshot = next
        }
    }

    /// Records current-frame perceptual equality and a future-policy anchor
    /// proposal. The proposal has no effect on the current persistence path.
    func recordPerceptualObservation(hash: UInt64, timestamp: Date, displayID: UUID?) {
        withLock {
            touchDisplay(displayID)
            var observation = observations[displayID] ?? DisplayObservation()
            let distance = observation.lastHash.map { PerceptualHash.hammingDistance(hash, $0) }

            if distance == 0 {
                snapshot = snapshot.replacing(perceptuallyEqualFrames: snapshot.perceptuallyEqualFrames + 1)
            }

            let isMajorChange = distance.map { $0 >= shadowAnchorPolicy.majorChangeHammingDistance } ?? false
            let canProposeMajor = observation.lastProposedMajorAnchor.map {
                timestamp.timeIntervalSince($0) >= shadowAnchorPolicy.majorChangeMinimumSpacing
            } ?? true
            let ordinaryAnchorIsDue = observation.lastProposedAnchor.map {
                timestamp.timeIntervalSince($0) >= shadowAnchorPolicy.ordinaryInterval
            } ?? true

            if isMajorChange && canProposeMajor {
                snapshot = snapshot.replacing(proposedMajorAnchors: snapshot.proposedMajorAnchors + 1)
                observation.lastProposedAnchor = timestamp
                observation.lastProposedMajorAnchor = timestamp
            } else if ordinaryAnchorIsDue {
                snapshot = snapshot.replacing(proposedOrdinaryAnchors: snapshot.proposedOrdinaryAnchors + 1)
                observation.lastProposedAnchor = timestamp
            }

            observation.lastHash = hash
            observations[displayID] = observation
        }
    }

    /// The comparison is against the last successfully persisted JPEG for
    /// this display. It is therefore exact byte equality, not a hash proxy.
    /// JPEGs over the small observer budget are deliberately not compared.
    func recordEncodedJPEG(
        _ data: Data,
        displayID: UUID?,
        compareAgainstPersistedBaseline: Bool = true
    ) {
        withLock {
            touchDisplay(displayID)
            var next = snapshot.replacing(
                encodedFrames: snapshot.encodedFrames + 1,
                largestEncodedJPEGBytes: max(snapshot.largestEncodedJPEGBytes, data.count)
            )
            guard data.count <= Self.maximumComparableJPEGBytes else {
                snapshot = next.replacing(exactComparisonSkippedFrames: next.exactComparisonSkippedFrames + 1)
                return
            }

            next = next.replacing(exactComparisonEligibleFrames: next.exactComparisonEligibleFrames + 1)
            if compareAgainstPersistedBaseline, let prior = lastPersistedJPEGData[displayID] {
                next = next.replacing(
                    exactComparisonBaselineAvailableFrames: next.exactComparisonBaselineAvailableFrames + 1
                )
                if prior.count == data.count, prior == data {
                    next = next.replacing(
                        repositoryExactDuplicateFrames: next.repositoryExactDuplicateFrames + 1
                    )
                }
            }
            snapshot = next
        }
    }

    func recordPersistedJPEG(_ data: Data, displayID: UUID?) {
        withLock {
            recordPersistedJPEGLocked(data, displayID: displayID)
        }
    }

    /// Records a promotion write receipt at most once per measurement epoch.
    /// Receipt values are freely copyable; their stable write token makes
    /// replay idempotent without moving metric ownership into FrameStore.
    func recordPersistedJPEG(receipt: DurableJPEGWriteReceipt) {
        withLock {
            guard recordedWriteReceiptTokens.insert(receipt.writeToken).inserted else {
                return
            }
            recordPersistedJPEGLocked(receipt.jpegData, displayID: receipt.displayID)
        }
    }

    func recordMetadataWrite(byteCount: Int) {
        withLock {
            snapshot = snapshot.replacing(
                logicalMetadataEventBytes: snapshot.logicalMetadataEventBytes + Int64(byteCount),
                metadataTransactions: snapshot.metadataTransactions + 1,
                largestMetadataWriteBytes: max(snapshot.largestMetadataWriteBytes, byteCount)
            )
        }
    }

    /// Records the repository's source-neutral save result after the caller
    /// has fenced cancellation and Clear-generation races. This is the sole
    /// repository path for durable byte metrics, preventing `FrameStore` and
    /// `FrameBuffer` from counting the same write twice.
    func recordRepositorySaveOutcome(
        _ outcome: FrameRepositorySaveOutcome,
        jpegData: Data,
        displayID: UUID?
    ) {
        withLock {
            switch outcome.disposition {
            case .durableFrame:
                snapshot = snapshot.replacing(
                    durableRepositorySaves: snapshot.durableRepositorySaves + 1
                )
            case .volatileFrame:
                snapshot = snapshot.replacing(
                    volatileRepositorySaves: snapshot.volatileRepositorySaves + 1
                )
            case .duplicateFrame:
                snapshot = snapshot.replacing(
                    duplicateRepositorySaves: snapshot.duplicateRepositorySaves + 1
                )
            case .spanCheckpoint:
                snapshot = snapshot.replacing(
                    spanCheckpointRepositorySaves: snapshot.spanCheckpointRepositorySaves + 1
                )
            case .pressureDrop:
                snapshot = snapshot.replacing(
                    pressureDroppedRepositorySaves: snapshot.pressureDroppedRepositorySaves + 1
                )
            }

            if outcome.wroteDurableJPEG {
                touchDisplay(displayID)
                updateComparisonData(jpegData, displayID: displayID)
                snapshot = snapshot.replacing(
                    persistedFrames: snapshot.persistedFrames + 1,
                    logicalDurableJPEGEventBytes: snapshot.logicalDurableJPEGEventBytes + Int64(jpegData.count)
                )
            }

            for byteCount in outcome.metadataWriteByteCounts {
                snapshot = snapshot.replacing(
                    logicalMetadataEventBytes: snapshot.logicalMetadataEventBytes + Int64(byteCount),
                    metadataTransactions: snapshot.metadataTransactions + 1,
                    largestMetadataWriteBytes: max(snapshot.largestMetadataWriteBytes, byteCount)
                )
            }
        }
    }

    /// Records actual source-neutral effects. Unlike the legacy single
    /// outcome, this preserves compound operations (for example, completing a
    /// pending promotion before admitting the current capture) and attributes
    /// durable anchors to the policy decision which caused the write.
    func recordRepositoryEffects(
        _ effects: FrameRepositoryEffects,
        acceptedJPEGData: Data? = nil,
        acceptedDisplayID: UUID? = nil
    ) {
        withLock {
            for event in effects.persistenceEvents {
                switch event {
                case .volatileAdmission:
                    snapshot = snapshot.replacing(
                        volatileRepositorySaves: snapshot.volatileRepositorySaves + 1
                    )

                case .exactDuplicate:
                    snapshot = snapshot.replacing(
                        repositoryExactDuplicateFrames:
                            snapshot.repositoryExactDuplicateFrames + 1,
                        duplicateRepositorySaves: snapshot.duplicateRepositorySaves + 1
                    )

                case .pressureDrop:
                    snapshot = snapshot.replacing(
                        pressureDroppedRepositorySaves: snapshot.pressureDroppedRepositorySaves + 1
                    )

                case .durableAnchor(
                    reason: let reason,
                    wroteDurableJPEG: let wroteDurableJPEG,
                    jpegData: let jpegData,
                    frameID: _,
                    displayID: let displayID,
                    metadataByteCount: let metadataByteCount
                ):
                    var next = snapshot.replacing(
                        durableRepositorySaves: snapshot.durableRepositorySaves + 1
                    )
                    switch reason {
                    case .firstInSession:
                        next = next.replacing(
                            firstAnchorRepositorySaves: next.firstAnchorRepositorySaves + 1
                        )
                    case .ordinary:
                        next = next.replacing(
                            ordinaryAnchorRepositorySaves: next.ordinaryAnchorRepositorySaves + 1
                        )
                    case .majorChange:
                        next = next.replacing(
                            majorChangeAnchorRepositorySaves: next.majorChangeAnchorRepositorySaves + 1
                        )
                    case .capacitySpill:
                        next = next.replacing(
                            capacitySpillRepositorySaves: next.capacitySpillRepositorySaves + 1
                        )
                    case .termination:
                        next = next.replacing(
                            terminationAnchorRepositorySaves: next.terminationAnchorRepositorySaves + 1
                        )
                    case .allDisk:
                        break
                    }
                    snapshot = next
                    if wroteDurableJPEG, let jpegData {
                        recordPersistedJPEGLocked(jpegData, displayID: displayID)
                    }
                    recordMetadataWriteLocked(metadataByteCount)

                case .spanCheckpoint(frameID: _, metadataByteCount: let metadataByteCount):
                    snapshot = snapshot.replacing(
                        spanCheckpointRepositorySaves: snapshot.spanCheckpointRepositorySaves + 1
                    )
                    recordMetadataWriteLocked(metadataByteCount)
                }
            }
            if let acceptedJPEGData {
                recordHybridRepositoryDecisionLocked(
                    effects,
                    jpegData: acceptedJPEGData,
                    displayID: acceptedDisplayID
                )
            }
        }
    }

    func currentSnapshot() -> CapturePersistenceInstrumentationSnapshot {
        withLock { snapshot }
    }

    /// Starts a new measurement epoch after a successful Clear All. All
    /// exact-comparison and shadow-anchor baselines are discarded with it.
    func reset() {
        withLock {
            let nextEpoch = snapshot.epoch + 1
            snapshot = .empty.replacing(epoch: nextEpoch)
            observations.removeAll(keepingCapacity: true)
            lastPersistedJPEGData.removeAll(keepingCapacity: true)
            lastAcceptedJPEGData.removeAll(keepingCapacity: true)
            trackedDisplayOrder.removeAll(keepingCapacity: true)
            recordedWriteReceiptTokens.removeAll(keepingCapacity: true)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Must be called while `lock` is held. The unlabelled legacy overload and
    /// receipt-aware overload deliberately share the metric update while only
    /// receipt calls participate in replay deduplication.
    private func recordPersistedJPEGLocked(_ data: Data, displayID: UUID?) {
        touchDisplay(displayID)
        updateComparisonData(data, displayID: displayID)
        snapshot = snapshot.replacing(
            persistedFrames: snapshot.persistedFrames + 1,
            logicalDurableJPEGEventBytes: snapshot.logicalDurableJPEGEventBytes + Int64(data.count)
        )
    }

    /// Must be called while `lock` is held.
    private func recordMetadataWriteLocked(_ byteCount: Int) {
        guard byteCount > 0 else { return }
        snapshot = snapshot.replacing(
            logicalMetadataEventBytes: snapshot.logicalMetadataEventBytes + Int64(byteCount),
            metadataTransactions: snapshot.metadataTransactions + 1,
            largestMetadataWriteBytes: max(snapshot.largestMetadataWriteBytes, byteCount)
        )
    }

    /// Must be called while `lock` is held. Keeping at most eight JPEGs of up
    /// to 2 MiB bounds this observer's retained comparison data to 16 MiB.
    private func updateComparisonData(_ data: Data, displayID: UUID?) {
        guard data.count <= Self.maximumComparableJPEGBytes else {
            lastPersistedJPEGData.removeValue(forKey: displayID)
            return
        }

        lastPersistedJPEGData[displayID] = data
    }

    /// Hybrid exact-duplicate metrics follow the repository's active accepted
    /// payload decision. This avoids comparing against an older durable JPEG
    /// across volatile admissions (for example A→RAM B→B or A→B→A).
    private func recordHybridRepositoryDecisionLocked(
        _ effects: FrameRepositoryEffects,
        jpegData: Data,
        displayID: UUID?
    ) {
        let wasPressureDropped = effects.persistenceEvents.contains {
            if case .pressureDrop = $0 { return true }
            return false
        }
        if wasPressureDropped {
            lastAcceptedJPEGData.removeValue(forKey: displayID)
            return
        }
        guard jpegData.count <= Self.maximumComparableJPEGBytes else {
            lastAcceptedJPEGData.removeValue(forKey: displayID)
            return
        }
        if lastAcceptedJPEGData[displayID] != nil {
            snapshot = snapshot.replacing(
                exactComparisonBaselineAvailableFrames:
                    snapshot.exactComparisonBaselineAvailableFrames + 1
            )
        }
        lastAcceptedJPEGData[displayID] = jpegData
    }

    /// Must be called while `lock` is held. One shared LRU bounds every
    /// per-display structure, including shadow observations and JPEG bases.
    private func touchDisplay(_ displayID: UUID?) {
        trackedDisplayOrder.removeAll { $0 == displayID }
        trackedDisplayOrder.append(displayID)

        while trackedDisplayOrder.count > Self.maximumTrackedDisplays {
            let evictedDisplayID = trackedDisplayOrder.removeFirst()
            observations.removeValue(forKey: evictedDisplayID)
            lastPersistedJPEGData.removeValue(forKey: evictedDisplayID)
            lastAcceptedJPEGData.removeValue(forKey: evictedDisplayID)
            snapshot = snapshot.replacing(displayStateEvictions: snapshot.displayStateEvictions + 1)
        }

        snapshot = snapshot.replacing(
            maximumObservedDisplays: max(snapshot.maximumObservedDisplays, trackedDisplayOrder.count),
            currentTrackedDisplays: trackedDisplayOrder.count
        )
    }
}

enum AsyncIngestDropReason: Sendable {
    case syncPriority
    case backlogLimit
}

private extension CapturePersistenceInstrumentationSnapshot {
    nonisolated func replacing(
        epoch: Int? = nil,
        capturedFrames: Int? = nil,
        encodedFrames: Int? = nil,
        persistedFrames: Int? = nil,
        exactComparisonEligibleFrames: Int? = nil,
        exactComparisonBaselineAvailableFrames: Int? = nil,
        exactComparisonSkippedFrames: Int? = nil,
        repositoryExactDuplicateFrames: Int? = nil,
        perceptuallyEqualFrames: Int? = nil,
        logicalDurableJPEGEventBytes: Int64? = nil,
        logicalMetadataEventBytes: Int64? = nil,
        metadataTransactions: Int? = nil,
        durableRepositorySaves: Int? = nil,
        volatileRepositorySaves: Int? = nil,
        duplicateRepositorySaves: Int? = nil,
        spanCheckpointRepositorySaves: Int? = nil,
        pressureDroppedRepositorySaves: Int? = nil,
        firstAnchorRepositorySaves: Int? = nil,
        ordinaryAnchorRepositorySaves: Int? = nil,
        majorChangeAnchorRepositorySaves: Int? = nil,
        capacitySpillRepositorySaves: Int? = nil,
        terminationAnchorRepositorySaves: Int? = nil,
        proposedOrdinaryAnchors: Int? = nil,
        proposedMajorAnchors: Int? = nil,
        maximumPreTrimIngestQueueDepth: Int? = nil,
        maximumIngestQueueDepth: Int? = nil,
        droppedAsyncIngests: Int? = nil,
        droppedAsyncIngestsForSyncPriority: Int? = nil,
        droppedAsyncIngestsForBacklogLimit: Int? = nil,
        largestEncodedJPEGBytes: Int? = nil,
        largestMetadataWriteBytes: Int? = nil,
        maximumObservedDisplays: Int? = nil,
        currentTrackedDisplays: Int? = nil,
        displayStateEvictions: Int? = nil
    ) -> Self {
        Self(
            epoch: epoch ?? self.epoch,
            capturedFrames: capturedFrames ?? self.capturedFrames,
            encodedFrames: encodedFrames ?? self.encodedFrames,
            persistedFrames: persistedFrames ?? self.persistedFrames,
            exactComparisonEligibleFrames: exactComparisonEligibleFrames ?? self.exactComparisonEligibleFrames,
            exactComparisonBaselineAvailableFrames: exactComparisonBaselineAvailableFrames ?? self.exactComparisonBaselineAvailableFrames,
            exactComparisonSkippedFrames: exactComparisonSkippedFrames ?? self.exactComparisonSkippedFrames,
            repositoryExactDuplicateFrames: repositoryExactDuplicateFrames ?? self.repositoryExactDuplicateFrames,
            perceptuallyEqualFrames: perceptuallyEqualFrames ?? self.perceptuallyEqualFrames,
            logicalDurableJPEGEventBytes: logicalDurableJPEGEventBytes ?? self.logicalDurableJPEGEventBytes,
            logicalMetadataEventBytes: logicalMetadataEventBytes ?? self.logicalMetadataEventBytes,
            metadataTransactions: metadataTransactions ?? self.metadataTransactions,
            durableRepositorySaves: durableRepositorySaves ?? self.durableRepositorySaves,
            volatileRepositorySaves: volatileRepositorySaves ?? self.volatileRepositorySaves,
            duplicateRepositorySaves: duplicateRepositorySaves ?? self.duplicateRepositorySaves,
            spanCheckpointRepositorySaves: spanCheckpointRepositorySaves ?? self.spanCheckpointRepositorySaves,
            pressureDroppedRepositorySaves: pressureDroppedRepositorySaves ?? self.pressureDroppedRepositorySaves,
            firstAnchorRepositorySaves: firstAnchorRepositorySaves ?? self.firstAnchorRepositorySaves,
            ordinaryAnchorRepositorySaves: ordinaryAnchorRepositorySaves ?? self.ordinaryAnchorRepositorySaves,
            majorChangeAnchorRepositorySaves: majorChangeAnchorRepositorySaves ?? self.majorChangeAnchorRepositorySaves,
            capacitySpillRepositorySaves: capacitySpillRepositorySaves ?? self.capacitySpillRepositorySaves,
            terminationAnchorRepositorySaves: terminationAnchorRepositorySaves ?? self.terminationAnchorRepositorySaves,
            proposedOrdinaryAnchors: proposedOrdinaryAnchors ?? self.proposedOrdinaryAnchors,
            proposedMajorAnchors: proposedMajorAnchors ?? self.proposedMajorAnchors,
            maximumPreTrimIngestQueueDepth: maximumPreTrimIngestQueueDepth ?? self.maximumPreTrimIngestQueueDepth,
            maximumIngestQueueDepth: maximumIngestQueueDepth ?? self.maximumIngestQueueDepth,
            droppedAsyncIngests: droppedAsyncIngests ?? self.droppedAsyncIngests,
            droppedAsyncIngestsForSyncPriority: droppedAsyncIngestsForSyncPriority ?? self.droppedAsyncIngestsForSyncPriority,
            droppedAsyncIngestsForBacklogLimit: droppedAsyncIngestsForBacklogLimit ?? self.droppedAsyncIngestsForBacklogLimit,
            largestEncodedJPEGBytes: largestEncodedJPEGBytes ?? self.largestEncodedJPEGBytes,
            largestMetadataWriteBytes: largestMetadataWriteBytes ?? self.largestMetadataWriteBytes,
            maximumObservedDisplays: maximumObservedDisplays ?? self.maximumObservedDisplays,
            currentTrackedDisplays: currentTrackedDisplays ?? self.currentTrackedDisplays,
            displayStateEvictions: displayStateEvictions ?? self.displayStateEvictions
        )
    }
}
