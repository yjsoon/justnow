//
//  HybridFrameRepository.swift
//  JustNow
//

import CoreGraphics
import Foundation

/// Keeps payload handling explicit at the RAM/disk boundary. The ring gives us
/// immutable encoded bytes; decoding is deliberately transient at the call
/// site and no decoded representation is retained by hybrid history.
nonisolated enum FramePayloadResolver {
    static func fullImage(from jpegData: Data) throws -> CGImage {
        guard let image = ImageEncoder.cgImage(from: jpegData) else {
            throw FrameStoreError.imageDecodingFailed
        }
        return image
    }

    static func thumbnail(from jpegData: Data) -> CGImage? {
        guard let image = ImageEncoder.cgImage(from: jpegData) else { return nil }
        return ImageEncoder.generateThumbnail(from: image)
    }

    static func searchImage(from jpegData: Data, maxPixelSize: Int) throws -> CGImage {
        guard let image = ImageEncoder.cgImage(from: jpegData, maxPixelSize: maxPixelSize) else {
            throw FrameStoreError.imageDecodingFailed
        }
        return image
    }
}

private actor HybridPayloadLease: FrameRepositoryPayloadLease {
    private let repository: HybridFrameRepository
    private let frameIDs: Set<UUID>
    private var didRelease = false

    init(repository: HybridFrameRepository, frameIDs: Set<UUID>) {
        self.repository = repository
        self.frameIDs = frameIDs
    }

    func release() async -> FrameRepositoryMaintenanceResult {
        guard !didRelease else { return .noOp }
        didRelease = true
        return await repository.releasePayloadLease(for: frameIDs)
    }
}

/// Serialises repository mutations across suspension points. Actor isolation
/// alone permits re-entrancy while awaiting the ring or durable source, which
/// could otherwise let a later capture observe stale active-payload state.
private actor HybridRepositoryMutationGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().resume()
    }
}

nonisolated struct HybridHistoryPolicy: Sendable, Equatable {
    let ordinaryAnchorInterval: TimeInterval
    let majorChangeHammingDistance: Int
    let majorChangeMinimumInterval: TimeInterval
    let mirroredCheckpointInterval: TimeInterval

    static let standard = Self(
        ordinaryAnchorInterval: 5,
        majorChangeHammingDistance: 12,
        majorChangeMinimumInterval: 1,
        mirroredCheckpointInterval: 30
    )
}

/// A launch-scoped hybrid source. SQLite owns durable anchors while the
/// bounded compressed ring owns recent exact bytes. Mirrored entries appear
/// once in the logical timeline; the newer absolute RAM span wins until its
/// next durable checkpoint.
actor HybridFrameRepository: FrameRepository {
    private enum Residency: Sendable, Equatable {
        case ringOnly
        case mirrored
        case durableOnly
    }

    private struct ActivePayload: Sendable, Equatable {
        var entry: TimelineEntry
        var residency: Residency
        var canonicalDurableEntry: TimelineEntry?
    }

    private struct ActiveCaptureKey: Hashable, Sendable {
        let sessionID: UUID
        let displayID: UUID?
    }

    private struct DisplayPolicyState: Sendable, Equatable {
        var active: ActivePayload?
        var lastAcceptedObservationAt: Date?
        var lastAcceptedHash: UInt64?
        var lastJPEGAnchorAt: Date?
        var lastMajorAnchorAt: Date?
    }

    private struct PendingPromotion: Sendable, Equatable {
        let entry: TimelineEntry
        let jpegData: Data
        let reason: FrameRepositoryDurableAnchorReason
        let acceptedAt: Date
        let acceptedHash: UInt64
    }

    private struct PromotionCompletion: Sendable {
        let entry: TimelineEntry
        let effects: FrameRepositoryEffects
        let wroteDurableJPEG: Bool
        let metadataByteCount: Int
    }

    private let disk: any HybridDurableRepository
    private let ring: CompressedFrameRing
    private let policy: HybridHistoryPolicy
    private let mutationGate = HybridRepositoryMutationGate()
    private var activeSession: CaptureSession?
    private var policyStates: [ActiveCaptureKey: DisplayPolicyState] = [:]
    private var pendingPromotions: [ActiveCaptureKey: PendingPromotion] = [:]
    /// Effects which committed before a later operation in the same capture
    /// call failed. They are re-emitted with the next successful result and
    /// removed only when that result can be delivered to FrameBuffer.
    private var pendingCaptureEffects: [ActiveCaptureKey: FrameRepositoryEffects] = [:]
    private var durableEntriesBySpanID: [UUID: TimelineEntry] = [:]
    /// Successful termination effects are retained until the durable session
    /// close also succeeds. A retry then returns every effect once without
    /// repeating promotions or checkpoints which already committed.
    private var pendingSessionEndEffects: [UUID: FrameRepositoryEffects] = [:]
    private var volatilePayloadResolutions = 0
    private var durablePayloadResolutions = 0

    init(
        frameStore: FrameStore,
        byteCap: Int = HistoryStorageMode.defaultHybridByteCap,
        policy: HybridHistoryPolicy = .standard
    ) {
        self.disk = DiskFrameRepository(frameStore: frameStore)
        self.ring = CompressedFrameRing(byteCap: byteCap)
        self.policy = policy
    }

    init(
        durableRepository: any HybridDurableRepository,
        byteCap: Int = HistoryStorageMode.defaultHybridByteCap,
        policy: HybridHistoryPolicy = .standard
    ) {
        self.disk = durableRepository
        self.ring = CompressedFrameRing(byteCap: byteCap)
        self.policy = policy
    }

    func captureAdmissionMode() async -> FrameCaptureAdmissionMode {
        .hybridEveryCapture
    }

    func cleanupOrphans() async throws {
        try await disk.cleanupOrphans()
    }

    func orderedFrames() async -> [StoredFrame] {
        let entries = await orderedTimeline()
        var framesByPhysicalID: [UUID: StoredFrame] = [:]
        for entry in entries {
            framesByPhysicalID[entry.frame.id] = entry.frame
        }
        return framesByPhysicalID.values.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    func orderedTimeline() async -> [TimelineEntry] {
        let durable = await disk.orderedTimeline()
        let resident = await ring.entries()
        return mergedTimeline(durable: durable, resident: resident)
    }

    private func mergedTimeline(
        durable: [TimelineEntry],
        resident: [TimelineEntry]
    ) -> [TimelineEntry] {
        var coalesced: [UUID: (entry: TimelineEntry, sourcePriority: Int)] = [:]
        for entry in durable {
            coalesced[entry.span.id] = (entry, 0)
        }
        for entry in resident {
            coalesce(entry, sourcePriority: 2, into: &coalesced)
        }
        for state in policyStates.values {
            guard let active = state.active, active.residency == .durableOnly else { continue }
            coalesce(active.entry, sourcePriority: 2, into: &coalesced)
        }
        return coalesced.values.map(\.entry).sorted(by: timelineOrder)
    }

    func beginCaptureSession(at startedAt: Date) async throws -> CaptureSession {
        try await withMutationPermit {
            let session = try await self.disk.beginCaptureSession(at: startedAt)
            self.activeSession = session
            return session
        }
    }

    func endCaptureSession(
        id: UUID,
        reason: CaptureSessionEndReason
    ) async throws -> FrameRepositoryEffects {
        try await withMutationPermit {
            var accumulated = self.pendingSessionEndEffects[id] ?? .empty
            if self.pendingSessionEndEffects[id] == nil {
                let outboxKeys = self.pendingCaptureEffects.keys
                    .filter { $0.sessionID == id }
                    .sorted(by: self.captureKeyOrder)
                for key in outboxKeys {
                    if let effects = self.pendingCaptureEffects.removeValue(forKey: key) {
                        accumulated.merge(effects)
                    }
                }
                self.pendingSessionEndEffects[id] = accumulated
            }

            let keys = Set(self.policyStates.keys)
                .union(self.pendingPromotions.keys)
                .union(self.pendingCaptureEffects.keys)
                .filter { $0.sessionID == id }
                .sorted(by: self.captureKeyOrder)
            // A pending promotion is an already-made durable policy decision,
            // not an ordinary tail flush. Complete it before every kind of
            // close so pause/sleep cannot strand its stable IDs in an orphan.
            for key in keys where self.pendingPromotions[key] != nil {
                let completion = try await self.completePendingPromotion(for: key)
                accumulated.merge(completion.effects)
                self.pendingSessionEndEffects[id] = accumulated
            }

            if reason == .termination {
                for key in keys {
                    guard let active = self.policyStates[key]?.active else { continue }
                    switch active.residency {
                    case .ringOnly:
                        guard let jpegData = await self.ring.data(frameID: active.entry.frame.id) else {
                            continue
                        }
                        self.pendingPromotions[key] = PendingPromotion(
                            entry: active.entry,
                            jpegData: jpegData,
                            reason: .termination,
                            acceptedAt: active.entry.span.observedThroughAt,
                            acceptedHash: active.entry.frame.hash
                        )
                        let completion = try await self.completePendingPromotion(for: key)
                        accumulated.merge(completion.effects)
                        self.pendingSessionEndEffects[id] = accumulated

                    case .mirrored, .durableOnly:
                        if let canonical = active.canonicalDurableEntry,
                           self.requiresDurableCheckpoint(active.entry, than: canonical) {
                            let effects = try await self.checkpointActivePayload(for: key)
                            accumulated.merge(effects)
                            self.pendingSessionEndEffects[id] = accumulated
                        }
                    }
                }
            }

            let diskEffects = try await self.disk.endCaptureSession(id: id, reason: reason)
            accumulated.merge(diskEffects)
            if self.activeSession?.id == id { self.activeSession = nil }
            self.policyStates = self.policyStates.filter { $0.key.sessionID != id }
            self.pendingPromotions = self.pendingPromotions.filter { $0.key.sessionID != id }
            self.pendingCaptureEffects = self.pendingCaptureEffects.filter {
                $0.key.sessionID != id
            }
            self.pendingSessionEndEffects.removeValue(forKey: id)
            return accumulated
        }
    }

    func recordEncodedCapture(
        _ frame: StoredFrame,
        jpegData: Data
    ) async throws -> FrameRepositorySaveResult {
        try await withMutationPermit {
            try await self.recordEncodedCaptureWithPermit(frame, jpegData: jpegData)
        }
    }

    private func recordEncodedCaptureWithPermit(
        _ frame: StoredFrame,
        jpegData: Data
    ) async throws -> FrameRepositorySaveResult {
        guard let session = activeSession else {
            throw FrameStoreError.noActiveCaptureSession
        }
        guard frame.timestamp.timeIntervalSince1970.isFinite,
              frame.timestamp >= session.startedAt else {
            throw FrameStoreError.staleCaptureObservation
        }

        let key = ActiveCaptureKey(sessionID: session.id, displayID: frame.displayID)
        if let lastAccepted = policyStates[key]?.lastAcceptedObservationAt,
           frame.timestamp < lastAccepted {
            throw FrameStoreError.staleCaptureObservation
        }

        var effects = pendingCaptureEffects[key] ?? .empty
        if let pending = pendingPromotions[key] {
            let retriesSameObservation = pending.acceptedAt == frame.timestamp
                && pending.jpegData == jpegData
            let completion = try await completePendingPromotion(for: key)
            effects.merge(completion.effects)
            pendingCaptureEffects[key] = effects
            if retriesSameObservation {
                return completeCaptureResult(FrameRepositorySaveResult(
                    mutation: .inserted(completion.entry),
                    outcome: .durableFrame(
                        wroteDurableJPEG: completion.wroteDurableJPEG,
                        metadataByteCount: completion.metadataByteCount
                    ),
                    effects: effects
                ), for: key)
            }
        }

        // Completing a previously failed promotion can advance this display's
        // accepted clock beyond the current queued capture. Revalidate after
        // that transition before comparing or constructing another span; the
        // committed prefix remains in `pendingCaptureEffects` if this throws.
        if let lastAccepted = policyStates[key]?.lastAcceptedObservationAt,
           frame.timestamp < lastAccepted {
            throw FrameStoreError.staleCaptureObservation
        }

        if let active = policyStates[key]?.active {
            do {
                if try await payloadMatches(active, jpegData: jpegData) {
                    let result = try await recordExactDuplicate(
                        frame,
                        jpegData: jpegData,
                        key: key,
                        active: active,
                        precedingEffects: effects
                    )
                    return completeCaptureResult(result, for: key)
                }
            } catch let error as FrameStoreError {
                // A durable-only active span may have had its payload removed
                // externally after RAM eviction. Do not let that broken span
                // wedge capture or remain visible while accepting a fresh
                // durable anchor. Other storage failures remain observable.
                guard case .fileNotFound = error else { throw error }
                effects.merge(try await discardUnavailableDurablePayload(active, for: key))
                pendingCaptureEffects[key] = effects
            }
        }

        let boundaryEffects = try await checkpointDurableOnlyBoundaryIfNeeded(for: key)
        effects.merge(boundaryEffects)
        if boundaryEffects != .empty {
            pendingCaptureEffects[key] = effects
        }

        let entry = makeTimelineEntry(frame: frame, sessionID: session.id)
        if let reason = anchorReason(for: frame, key: key) {
            pendingPromotions[key] = PendingPromotion(
                entry: entry,
                jpegData: jpegData,
                reason: reason,
                acceptedAt: frame.timestamp,
                acceptedHash: frame.hash
            )
            let completion = try await completePendingPromotion(for: key)
            effects.merge(completion.effects)
            return completeCaptureResult(FrameRepositorySaveResult(
                mutation: .inserted(completion.entry),
                outcome: .durableFrame(
                    wroteDurableJPEG: completion.wroteDurableJPEG,
                    metadataByteCount: completion.metadataByteCount
                ),
                effects: effects
            ), for: key)
        }

        let admission = await ring.admit(entry: entry, jpegData: jpegData)
        switch admission {
        case .inserted(let inserted, let eviction):
            effects.merge(handleEviction(eviction))
            updateAcceptedState(
                for: key,
                active: ActivePayload(
                    entry: inserted,
                    residency: .ringOnly,
                    canonicalDurableEntry: nil
                ),
                observedAt: frame.timestamp,
                hash: frame.hash,
                anchorReason: nil
            )
            effects.timelineUpserts.append(inserted)
            effects.persistenceEvents.append(.volatileAdmission)
            return completeCaptureResult(FrameRepositorySaveResult(
                mutation: .inserted(inserted),
                outcome: .volatileFrame,
                effects: effects
            ), for: key)

        case .discardedForPressure:
            var state = policyStates[key] ?? DisplayPolicyState()
            // A deliberately dropped distinct observation is a real history
            // boundary. Otherwise a later matching image could extend the
            // prior span across content JustNow never recorded.
            state.active = nil
            state.lastAcceptedObservationAt = frame.timestamp
            state.lastAcceptedHash = frame.hash
            policyStates[key] = state
            effects.persistenceEvents.append(.pressureDrop)
            return completeCaptureResult(FrameRepositorySaveResult(
                mutation: .none,
                outcome: .pressureDrop,
                effects: effects
            ), for: key)

        case .needsDurableSpill:
            pendingPromotions[key] = PendingPromotion(
                entry: entry,
                jpegData: jpegData,
                reason: .capacitySpill,
                acceptedAt: frame.timestamp,
                acceptedHash: frame.hash
            )
            let completion = try await completePendingPromotion(for: key)
            effects.merge(completion.effects)
            return completeCaptureResult(FrameRepositorySaveResult(
                mutation: .inserted(completion.entry),
                outcome: .durableFrame(
                    wroteDurableJPEG: completion.wroteDurableJPEG,
                    metadataByteCount: completion.metadataByteCount
                ),
                effects: effects
            ), for: key)
        }
    }

    func loadFullImage(id: UUID) async throws -> CGImage {
        if let data = await ring.data(frameID: id) {
            volatilePayloadResolutions += 1
            return try FramePayloadResolver.fullImage(from: data)
        }
        let image = try await disk.loadFullImage(id: id)
        durablePayloadResolutions += 1
        return image
    }

    func loadThumbnail(id: UUID) async -> CGImage? {
        if let data = await ring.data(frameID: id) {
            volatilePayloadResolutions += 1
            return FramePayloadResolver.thumbnail(from: data)
        }
        let image = await disk.loadThumbnail(id: id)
        if image != nil { durablePayloadResolutions += 1 }
        return image
    }

    func loadSearchIndexImage(id: UUID, maxPixelSize: Int) async throws -> CGImage {
        if let data = await ring.data(frameID: id) {
            volatilePayloadResolutions += 1
            return try FramePayloadResolver.searchImage(from: data, maxPixelSize: maxPixelSize)
        }
        let image = try await disk.loadSearchIndexImage(id: id, maxPixelSize: maxPixelSize)
        durablePayloadResolutions += 1
        return image
    }

    func exportFrame(id: UUID, timestamp: Date) async throws -> URL {
        if let data = await ring.data(frameID: id) {
            volatilePayloadResolutions += 1
            return try await disk.exportEncodedPayload(data, timestamp: timestamp)
        }
        let url = try await disk.exportFrame(id: id, timestamp: timestamp)
        durablePayloadResolutions += 1
        return url
    }

    func exportCroppedImage(_ image: CGImage, timestamp: Date) async throws -> URL {
        try await disk.exportCroppedImage(image, timestamp: timestamp)
    }

    func acquirePayloadLease(for physicalFrameIDs: Set<UUID>) async -> any FrameRepositoryPayloadLease {
        let leasedIDs = await ring.acquireLease(for: physicalFrameIDs)
        return HybridPayloadLease(repository: self, frameIDs: leasedIDs)
    }

    func acquireCurrentTimelineSnapshotLease() async -> FrameRepositoryLeasedTimelineSnapshot {
        await withMutationPermit {
            let durableEntries = await self.disk.orderedTimeline()
            let residentSnapshot = await self.ring.acquireTimelineSnapshotLease()
            let lease = HybridPayloadLease(
                repository: self,
                frameIDs: residentSnapshot.leasedFrameIDs
            )
            return FrameRepositoryLeasedTimelineSnapshot(
                entries: self.mergedTimeline(
                    durable: durableEntries,
                    resident: residentSnapshot.entries
                ),
                lease: lease
            )
        }
    }

    func payloadResolutionStatistics() async -> FramePayloadResolutionStatistics {
        return FramePayloadResolutionStatistics(
            volatilePayloadResolutions: volatilePayloadResolutions,
            durablePayloadResolutions: durablePayloadResolutions
        )
    }

    fileprivate func releasePayloadLease(
        for frameIDs: Set<UUID>
    ) async -> FrameRepositoryMaintenanceResult {
        await withMutationPermit {
            let maintenance = await self.ring.releaseLease(for: frameIDs)
            return self.maintenanceResult(for: maintenance)
        }
    }

    func respondToMemoryPressure(
        _ level: FrameMemoryPressureLevel
    ) async -> FrameRepositoryMaintenanceResult {
        await withMutationPermit {
            let maintenance: CompressedFrameRing.Maintenance
            switch level {
            case .warning:
                maintenance = await self.ring.reduceForWarning()
            case .critical:
                maintenance = await self.ring.dropAllForCriticalPressure()
            }
            return self.maintenanceResult(for: maintenance)
        }
    }

    func pruneSpans(ids: Set<UUID>) async throws -> FrameRepositoryInvalidation {
        try await withMutationPermit {
            try await self.pruneSpansWithMutationPermit(ids: ids)
        }
    }

    private func pruneSpansWithMutationPermit(
        ids: Set<UUID>
    ) async throws -> FrameRepositoryInvalidation {
        let durableInvalidation = try await disk.pruneSpans(ids: ids)
        let residentEviction = await ring.removeSpans(ids: ids)
        let removedFrameIDs = Set(residentEviction.entries.map(\.frame.id))
        let stillInRing = Set((await ring.entries()).map(\.frame.id))
        let durableCandidates = removedFrameIDs.subtracting(stillInRing)
        let stillDurable: Set<UUID>
        do {
            stillDurable = try await disk.referencedFrameIDs(among: durableCandidates)
        } catch {
            // Durable pruning has already committed. On a follow-up read
            // failure, conservatively retain decoded/cache state rather
            // than throwing after both repositories have mutated.
            stillDurable = durableCandidates
        }
        let survivingFrameIDs = stillInRing.union(stillDurable)
        let removedSpanIDs = Set(residentEviction.entries.map(\.span.id))
            .union(durableInvalidation.spanIDs)
        removePolicyState(spanIDs: removedSpanIDs, frameIDs: removedFrameIDs)
        reconcilePendingEffectsAfterPrune(spanIDs: removedSpanIDs)
        for spanID in removedSpanIDs {
            durableEntriesBySpanID.removeValue(forKey: spanID)
        }
        return FrameRepositoryInvalidation(
            spanIDs: removedSpanIDs,
            finalPhysicalFrameIDs: durableInvalidation.finalPhysicalFrameIDs
                .union(removedFrameIDs.subtracting(survivingFrameIDs))
        )
    }

    func clear() async throws {
        try await withMutationPermit {
            var committedCleanupError: Error?
            do {
                try await self.disk.clear()
            } catch let error as FrameStoreError {
                guard case .clearIncomplete = error else { throw error }
                // Logical deletion committed. The failed file paths remain
                // tracked by FrameStore for a later exact retry, so RAM and
                // session state must cross the same clear boundary now.
                committedCleanupError = error
            }
            _ = await self.ring.clear()
            self.policyStates.removeAll(keepingCapacity: false)
            self.pendingPromotions.removeAll(keepingCapacity: false)
            self.pendingCaptureEffects.removeAll(keepingCapacity: false)
            self.durableEntriesBySpanID.removeAll(keepingCapacity: false)
            self.pendingSessionEndEffects.removeAll(keepingCapacity: false)
            self.activeSession = nil
            self.volatilePayloadResolutions = 0
            self.durablePayloadResolutions = 0
            if let committedCleanupError {
                throw committedCleanupError
            }
        }
    }

    func durableJPEGPayloadBytes() async -> Int64 {
        await disk.durableJPEGPayloadBytes()
    }

    func storageStatistics() async -> FrameStorageStatistics {
        await withMutationPermit {
            let residentTimeline = await self.ring.entries()
            let resident = await self.ring.statistics()
            var knownDurableEntries = self.durableEntriesBySpanID
            var overlayBySpanID = Dictionary(
                uniqueKeysWithValues: residentTimeline.map { ($0.span.id, $0) }
            )
            for state in self.policyStates.values {
                guard let active = state.active else { continue }
                if let canonical = active.canonicalDurableEntry {
                    knownDurableEntries[canonical.span.id] = canonical
                }
                if active.residency == .durableOnly {
                    overlayBySpanID[active.entry.span.id] = active.entry
                }
            }
            let overlayTimeline = Array(overlayBySpanID.values)
            let durableSnapshot = await self.disk.durableStorageSnapshot(
                logicalOverlay: overlayTimeline
            )
            let durable = durableSnapshot.statistics
            let knownDurableFrameIDs = Set(knownDurableEntries.values.map(\.frame.id))
            let additionalFrameIDs = Set(
                overlayTimeline.compactMap { entry in
                    knownDurableFrameIDs.contains(entry.frame.id) ? nil : entry.frame.id
                }
            )
            let additionalSpanCount = overlayTimeline.reduce(0) { count, entry in
                count + (knownDurableEntries[entry.span.id] == nil ? 1 : 0)
            }
            let additionalObservationCount = overlayTimeline.reduce(0) { count, entry in
                guard let canonical = knownDurableEntries[entry.span.id] else {
                    return count + entry.span.observationCount
                }
                return count + max(
                    0,
                    entry.span.observationCount - canonical.span.observationCount
                )
            }
            return FrameStorageStatistics(
                durableJPEGPayloadBytes: durable.durableJPEGPayloadBytes,
                knownSQLiteAllocatedBytes: durable.knownSQLiteAllocatedBytes,
                sqliteWALAllocatedBytes: durable.sqliteWALAllocatedBytes,
                frameCount: durable.frameCount + additionalFrameIDs.count,
                durableFrameCount: durable.durableFrameCount,
                timelineSpanCount: durable.timelineSpanCount + additionalSpanCount,
                observationCount: durable.observationCount + additionalObservationCount,
                projectionSamples: durable.projectionSamples,
                volatileBytes: Int64(resident.totalBytes),
                volatileByteCap: Int64(resident.byteCap),
                configuredVolatileByteCap: Int64(resident.configuredByteCap),
                volatileFrameCount: resident.payloadCount,
                volatileTimelineSpanCount: resident.spanCount,
                volatileObservationCount: resident.observationCount,
                volatileCoverageStart: resident.coverageStart,
                volatileCoverageEnd: resident.coverageEnd,
                displayCoverage: FrameCoverageCalculator.attachingVolatile(
                    to: durable.displayCoverage,
                    volatile: residentTimeline
                )
            )
        }
    }

    func flush() async {
        await disk.flush()
    }

    private func recordExactDuplicate(
        _ frame: StoredFrame,
        jpegData: Data,
        key: ActiveCaptureKey,
        active: ActivePayload,
        precedingEffects: FrameRepositoryEffects
    ) async throws -> FrameRepositorySaveResult {
        let proposed = extending(active.entry, with: frame)
        var effects = precedingEffects
        effects.persistenceEvents.append(.exactDuplicate)

        if active.residency == .ringOnly,
           hasElapsed(
               policy.ordinaryAnchorInterval,
               since: policyStates[key]?.lastJPEGAnchorAt,
               at: frame.timestamp
           ) {
            pendingPromotions[key] = PendingPromotion(
                entry: proposed,
                jpegData: jpegData,
                reason: .ordinary,
                acceptedAt: frame.timestamp,
                acceptedHash: frame.hash
            )
            // The exact observation is part of the pending absolute span. If
            // promotion fails, retain its event alongside any earlier
            // committed prefix so the eventual retry reports both once.
            pendingCaptureEffects[key] = effects
            let completion = try await completePendingPromotion(for: key)
            effects.merge(completion.effects)
            return FrameRepositorySaveResult(
                mutation: .extended(completion.entry.span),
                outcome: .durableFrame(
                    wroteDurableJPEG: completion.wroteDurableJPEG,
                    metadataByteCount: completion.metadataByteCount
                ),
                effects: effects
            )
        }

        if active.residency != .ringOnly,
           let canonical = active.canonicalDurableEntry,
           hasElapsed(
               policy.mirroredCheckpointInterval,
               since: canonical.span.observedThroughAt,
               at: proposed.span.observedThroughAt
           ) {
            let result = try await disk.checkpointPromotedSpan(proposed.span)
            durableEntriesBySpanID[result.entry.span.id] = result.entry
            let reconciled = await ring.reconcile(entry: result.entry)
            let currentEntry = reconciled ?? result.entry
            var updated = active
            updated.entry = currentEntry
            updated.canonicalDurableEntry = result.entry
            policyStates[key]?.active = updated
            policyStates[key]?.lastAcceptedObservationAt = frame.timestamp
            policyStates[key]?.lastAcceptedHash = frame.hash
            effects.timelineUpserts.append(currentEntry)
            if result.logicalMetadataByteCount > 0 {
                effects.persistenceEvents.append(
                    .spanCheckpoint(
                        frameID: currentEntry.frame.id,
                        metadataByteCount: result.logicalMetadataByteCount
                    )
                )
            }
            return FrameRepositorySaveResult(
                mutation: .extended(currentEntry.span),
                outcome: .spanCheckpoint(
                    metadataByteCount: result.logicalMetadataByteCount
                ),
                effects: effects
            )
        }

        let reconciled: TimelineEntry?
        if active.residency == .durableOnly {
            reconciled = nil
        } else {
            reconciled = await ring.reconcile(entry: proposed)
        }
        let currentEntry = reconciled ?? proposed
        var updated = active
        updated.entry = currentEntry
        policyStates[key]?.active = updated
        policyStates[key]?.lastAcceptedObservationAt = frame.timestamp
        policyStates[key]?.lastAcceptedHash = frame.hash
        effects.timelineUpserts.append(currentEntry)
        return FrameRepositorySaveResult(
            mutation: .extended(currentEntry.span),
            outcome: .duplicateFrame,
            effects: effects
        )
    }

    private func completeCaptureResult(
        _ result: FrameRepositorySaveResult,
        for key: ActiveCaptureKey
    ) -> FrameRepositorySaveResult {
        pendingCaptureEffects.removeValue(forKey: key)
        return result
    }

    private func completePendingPromotion(
        for key: ActiveCaptureKey
    ) async throws -> PromotionCompletion {
        guard let pending = pendingPromotions[key] else {
            preconditionFailure("Missing pending promotion")
        }
        let result = try await disk.promoteVolatileEntry(
            pending.entry,
            jpegData: pending.jpegData
        )
        durableEntriesBySpanID[result.entry.span.id] = result.entry

        var effects = FrameRepositoryEffects.empty
        let currentEntry: TimelineEntry
        let residency: Residency
        if await ring.contains(frameID: result.entry.frame.id) {
            currentEntry = await ring.reconcile(entry: result.entry) ?? result.entry
            residency = .mirrored
        } else if pending.reason != .capacitySpill {
            switch await ring.admit(entry: result.entry, jpegData: pending.jpegData) {
            case .inserted(let inserted, let eviction):
                effects.merge(handleEviction(eviction))
                currentEntry = inserted
                residency = .mirrored
            case .needsDurableSpill, .discardedForPressure:
                currentEntry = result.entry
                residency = .durableOnly
            }
        } else {
            currentEntry = result.entry
            residency = .durableOnly
        }

        updateAcceptedState(
            for: key,
            active: ActivePayload(
                entry: currentEntry,
                residency: residency,
                canonicalDurableEntry: result.entry
            ),
            observedAt: pending.acceptedAt,
            hash: pending.acceptedHash,
            anchorReason: pending.reason
        )
        pendingPromotions.removeValue(forKey: key)

        effects.timelineUpserts.append(currentEntry)
        effects.newlyDurableEntries.append(currentEntry)
        effects.persistenceEvents.append(
            .durableAnchor(
                reason: pending.reason,
                wroteDurableJPEG: result.wroteDurableJPEG,
                jpegData: result.wroteDurableJPEG ? pending.jpegData : nil,
                frameID: currentEntry.frame.id,
                displayID: currentEntry.span.displayID,
                metadataByteCount: result.logicalMetadataByteCount
            )
        )
        return PromotionCompletion(
            entry: currentEntry,
            effects: effects,
            wroteDurableJPEG: result.wroteDurableJPEG,
            metadataByteCount: result.logicalMetadataByteCount
        )
    }

    private func checkpointDurableOnlyBoundaryIfNeeded(
        for key: ActiveCaptureKey
    ) async throws -> FrameRepositoryEffects {
        guard let active = policyStates[key]?.active,
              active.residency == .durableOnly,
              let canonical = active.canonicalDurableEntry,
              requiresDurableCheckpoint(active.entry, than: canonical) else {
            return .empty
        }
        return try await checkpointActivePayload(for: key)
    }

    private func checkpointActivePayload(
        for key: ActiveCaptureKey
    ) async throws -> FrameRepositoryEffects {
        guard var active = policyStates[key]?.active else { return .empty }
        let result = try await disk.checkpointPromotedSpan(active.entry.span)
        durableEntriesBySpanID[result.entry.span.id] = result.entry
        let reconciled = await ring.reconcile(entry: result.entry)
        active.entry = reconciled ?? result.entry
        active.canonicalDurableEntry = result.entry
        policyStates[key]?.active = active

        var effects = FrameRepositoryEffects.empty
        effects.timelineUpserts.append(active.entry)
        if result.logicalMetadataByteCount > 0 {
            effects.persistenceEvents.append(
                .spanCheckpoint(
                    frameID: active.entry.frame.id,
                    metadataByteCount: result.logicalMetadataByteCount
                )
            )
        }
        return effects
    }

    private func payloadMatches(
        _ active: ActivePayload,
        jpegData: Data
    ) async throws -> Bool {
        if let residentData = await ring.data(frameID: active.entry.frame.id) {
            return residentData == jpegData
        }
        guard active.canonicalDurableEntry != nil else { return false }
        return try await disk.encodedPayload(id: active.entry.frame.id) == jpegData
    }

    private func discardUnavailableDurablePayload(
        _ active: ActivePayload,
        for key: ActiveCaptureKey
    ) async throws -> FrameRepositoryEffects {
        let invalidation = try await pruneSpansWithMutationPermit(ids: [active.entry.span.id])
        // Unlike ordinary retention, this is a recovery boundary. Reset its
        // anchor clock so the observation that exposed the unavailable payload
        // is durably anchored as fresh history instead of being pressure-dropped.
        policyStates.removeValue(forKey: key)
        return FrameRepositoryEffects(
            timelineUpserts: [],
            invalidation: invalidation,
            newlyDurableEntries: [],
            persistenceEvents: []
        )
    }

    private func anchorReason(
        for frame: StoredFrame,
        key: ActiveCaptureKey
    ) -> FrameRepositoryDurableAnchorReason? {
        guard let state = policyStates[key], let lastAnchor = state.lastJPEGAnchorAt else {
            return .firstInSession
        }
        if frame.hash != 0,
           let previousHash = state.lastAcceptedHash,
           previousHash != 0,
           PerceptualHash.hammingDistance(frame.hash, previousHash)
               >= policy.majorChangeHammingDistance,
           hasElapsed(
               policy.majorChangeMinimumInterval,
               since: state.lastMajorAnchorAt ?? state.lastJPEGAnchorAt,
               at: frame.timestamp
           ) {
            return .majorChange
        }
        if hasElapsed(policy.ordinaryAnchorInterval, since: lastAnchor, at: frame.timestamp) {
            return .ordinary
        }
        return nil
    }

    private func updateAcceptedState(
        for key: ActiveCaptureKey,
        active: ActivePayload,
        observedAt: Date,
        hash: UInt64,
        anchorReason: FrameRepositoryDurableAnchorReason?
    ) {
        var state = policyStates[key] ?? DisplayPolicyState()
        state.active = active
        state.lastAcceptedObservationAt = observedAt
        state.lastAcceptedHash = hash
        if let anchorReason {
            state.lastJPEGAnchorAt = observedAt
            if anchorReason == .majorChange {
                state.lastMajorAnchorAt = observedAt
            }
        }
        policyStates[key] = state
    }

    private func handleEviction(
        _ eviction: CompressedFrameRing.Eviction
    ) -> FrameRepositoryEffects {
        var invalidatedSpanIDs: Set<UUID> = []
        var invalidatedFrameIDs: Set<UUID> = []
        var fallbackUpserts: [TimelineEntry] = []

        for entry in eviction.entries {
            let canonical = durableEntriesBySpanID[entry.span.id]
            let matchingKeys = policyStates.compactMap { key, state in
                state.active?.entry.span.id == entry.span.id ? key : nil
            }
            if let canonical {
                fallbackUpserts.append(canonical)
                for key in matchingKeys {
                    policyStates[key]?.active = ActivePayload(
                        entry: canonical,
                        residency: .durableOnly,
                        canonicalDurableEntry: canonical
                    )
                }
            } else {
                invalidatedSpanIDs.insert(entry.span.id)
                invalidatedFrameIDs.insert(entry.frame.id)
                for key in matchingKeys {
                    policyStates[key]?.active = nil
                }
            }
        }
        return FrameRepositoryEffects(
            timelineUpserts: fallbackUpserts,
            invalidation: FrameRepositoryInvalidation(
                spanIDs: invalidatedSpanIDs,
                finalPhysicalFrameIDs: invalidatedFrameIDs
            ),
            newlyDurableEntries: [],
            persistenceEvents: []
        )
    }

    private func maintenanceResult(
        for maintenance: CompressedFrameRing.Maintenance
    ) -> FrameRepositoryMaintenanceResult {
        FrameRepositoryMaintenanceResult(
            effects: handleEviction(maintenance.eviction),
            bytesBefore: Int64(maintenance.bytesBefore),
            bytesAfter: Int64(maintenance.bytesAfter),
            targetBytes: Int64(maintenance.targetBytes)
        )
    }

    private func removePolicyState(spanIDs: Set<UUID>, frameIDs: Set<UUID>) {
        for key in policyStates.keys {
            guard let active = policyStates[key]?.active else { continue }
            if spanIDs.contains(active.entry.span.id) || frameIDs.contains(active.entry.frame.id) {
                policyStates[key]?.active = nil
            }
        }
        pendingPromotions = pendingPromotions.filter {
            !spanIDs.contains($0.value.entry.span.id)
                && !frameIDs.contains($0.value.entry.frame.id)
        }
    }

    /// A durable operation may commit and enter an outbox before a later
    /// session-close step fails. Retention is authoritative after it commits:
    /// retries must never replay an upsert/newly-durable entry for a span that
    /// was pruned in the meantime.
    private func reconcilePendingEffectsAfterPrune(spanIDs: Set<UUID>) {
        guard !spanIDs.isEmpty else { return }
        for key in Array(pendingCaptureEffects.keys) {
            guard let effects = pendingCaptureEffects[key] else { continue }
            pendingCaptureEffects[key] = removingPrunedSpans(spanIDs, from: effects)
        }
        for sessionID in Array(pendingSessionEndEffects.keys) {
            guard let effects = pendingSessionEndEffects[sessionID] else { continue }
            pendingSessionEndEffects[sessionID] = removingPrunedSpans(spanIDs, from: effects)
        }
    }

    private func removingPrunedSpans(
        _ spanIDs: Set<UUID>,
        from effects: FrameRepositoryEffects
    ) -> FrameRepositoryEffects {
        FrameRepositoryEffects(
            timelineUpserts: effects.timelineUpserts.filter { !spanIDs.contains($0.span.id) },
            invalidation: effects.invalidation,
            newlyDurableEntries: effects.newlyDurableEntries.filter {
                !spanIDs.contains($0.span.id)
            },
            // Persistence events are aggregate receipts and cannot resurrect
            // policy state. Retain them so a committed logical write is still
            // reported exactly once even if retention immediately removes it.
            persistenceEvents: effects.persistenceEvents
        )
    }

    private func coalesce(
        _ entry: TimelineEntry,
        sourcePriority: Int,
        into values: inout [UUID: (entry: TimelineEntry, sourcePriority: Int)]
    ) {
        guard let existing = values[entry.span.id] else {
            values[entry.span.id] = (entry, sourcePriority)
            return
        }
        guard existing.entry.frame.id == entry.frame.id,
              existing.entry.span.sessionID == entry.span.sessionID else {
            return
        }
        if isLogicallyNewer(entry, than: existing.entry)
            || (!isLogicallyNewer(existing.entry, than: entry)
                && sourcePriority > existing.sourcePriority) {
            values[entry.span.id] = (entry, sourcePriority)
        }
    }

    private func isLogicallyNewer(_ lhs: TimelineEntry, than rhs: TimelineEntry) -> Bool {
        if lhs.span.observedThroughAt != rhs.span.observedThroughAt {
            return lhs.span.observedThroughAt > rhs.span.observedThroughAt
        }
        if lhs.span.observationCount != rhs.span.observationCount {
            return lhs.span.observationCount > rhs.span.observationCount
        }
        return lhs.span.displayName != nil && rhs.span.displayName == nil
    }

    /// Checkpoint comparisons retain name-only updates even though merge order
    /// leaves equal-ranked named entries to deterministic source priority.
    private func requiresDurableCheckpoint(
        _ lhs: TimelineEntry,
        than rhs: TimelineEntry
    ) -> Bool {
        isLogicallyNewer(lhs, than: rhs)
            || lhs.span.displayName != rhs.span.displayName
    }

    private func timelineOrder(_ lhs: TimelineEntry, _ rhs: TimelineEntry) -> Bool {
        let lhsStart = timelineSpanBounds(for: lhs).start
        let rhsStart = timelineSpanBounds(for: rhs).start
        if lhsStart != rhsStart { return lhsStart < rhsStart }
        return lhs.span.id.uuidString < rhs.span.id.uuidString
    }

    private func captureKeyOrder(_ lhs: ActiveCaptureKey, _ rhs: ActiveCaptureKey) -> Bool {
        switch (lhs.displayID, rhs.displayID) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case (.some(let lhsID), .some(let rhsID)):
            return lhsID.uuidString < rhsID.uuidString
        }
    }

    private func makeTimelineEntry(frame: StoredFrame, sessionID: UUID) -> TimelineEntry {
        TimelineEntry(
            span: TimelineSpan(
                id: UUID(),
                frameID: frame.id,
                sessionID: sessionID,
                startedAt: frame.timestamp,
                observedThroughAt: frame.timestamp,
                observationCount: 1,
                displayID: frame.displayID,
                displayName: frame.displayName
            ),
            frame: frame
        )
    }

    private func extending(_ entry: TimelineEntry, with observation: StoredFrame) -> TimelineEntry {
        TimelineEntry(
            span: TimelineSpan(
                id: entry.span.id,
                frameID: entry.span.frameID,
                sessionID: entry.span.sessionID,
                startedAt: entry.span.startedAt,
                observedThroughAt: observation.timestamp,
                observationCount: entry.span.observationCount + 1,
                displayID: entry.span.displayID,
                displayName: observation.displayName ?? entry.span.displayName
            ),
            frame: entry.frame
        )
    }

    private func hasElapsed(
        _ interval: TimeInterval,
        since date: Date?,
        at current: Date
    ) -> Bool {
        guard let date else { return false }
        // SQLite reconstructs Date from epoch doubles. One microsecond covers
        // that round-trip without admitting the explicit 0.999/4.999/29.999s
        // below-threshold policy cases.
        return current.timeIntervalSince(date) + 0.000_001 >= interval
    }

    private func withMutationPermit<T>(
        _ operation: () async throws -> T
    ) async rethrows -> T {
        await mutationGate.acquire()
        do {
            let value = try await operation()
            await mutationGate.release()
            return value
        } catch {
            await mutationGate.release()
            throw error
        }
    }
}
