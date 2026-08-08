//
//  CompressedFrameRing.swift
//  JustNow
//

import Foundation

/// Launch-scoped RAM history that owns compressed JPEG bytes only. It never
/// retains `CGImage`, thumbnails, OCR layouts, or other decoded image state.
/// The single cap is deliberately global across displays.
actor CompressedFrameRing {
    struct Statistics: Sendable, Equatable {
        let totalBytes: Int
        let byteCap: Int
        let configuredByteCap: Int
        let payloadCount: Int
        let spanCount: Int
        let observationCount: Int
        /// Timeline bounds of the RAM-resident spans. They deliberately do
        /// not imply that the interval is gap-free.
        let coverageStart: Date?
        let coverageEnd: Date?
    }

    struct Eviction: Sendable, Equatable {
        let entries: [TimelineEntry]

        static let none = Eviction(entries: [])
    }

    struct Maintenance: Sendable, Equatable {
        let eviction: Eviction
        let bytesBefore: Int
        let bytesAfter: Int
        let targetBytes: Int
    }

    /// The entries and physical IDs leased in one actor-isolated operation.
    /// No admission can interleave between reading this snapshot and pinning
    /// its payloads.
    struct LeasedSnapshot: Sendable, Equatable {
        let entries: [TimelineEntry]
        let leasedFrameIDs: Set<UUID>
    }

    enum Admission: Sendable, Equatable {
        case inserted(entry: TimelineEntry, eviction: Eviction)
        /// Critical pressure disables volatile admission for the launch. The
        /// repository may deliberately drop a non-anchor observation instead
        /// of turning the zero RAM budget into continuous disk spill.
        case discardedForPressure
        /// A current capture must be saved durably. Existing payloads remain
        /// untouched when the prospective insert cannot fit, so a failed
        /// admission never discards useful history merely to spill to disk.
        case needsDurableSpill
    }

    private struct Payload: Sendable {
        var entry: TimelineEntry
        let data: Data
    }

    private let configuredByteCap: Int
    private var effectiveByteCap: Int
    private var totalBytes = 0
    private var payloads: [UUID: Payload] = [:]
    /// Insertion order is the eviction order, independent of display.
    private var fifoFrameIDs: [UUID] = []
    private var leaseCounts: [UUID: Int] = [:]

    init(byteCap: Int) {
        configuredByteCap = max(0, byteCap)
        effectiveByteCap = max(0, byteCap)
    }

    func admit(
        frame: StoredFrame,
        jpegData: Data,
        sessionID: UUID
    ) -> Admission {
        admit(
            entry: TimelineEntry(
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
            ),
            jpegData: jpegData
        )
    }

    /// Admits a caller-owned stable identity. Durable anchors can therefore
    /// commit the exact same frame/span IDs before retaining their recent copy
    /// in RAM.
    func admit(entry: TimelineEntry, jpegData: Data) -> Admission {
        guard effectiveByteCap > 0 else { return .discardedForPressure }
        guard jpegData.count <= effectiveByteCap else { return .needsDurableSpill }
        guard entry.span.frameID == entry.frame.id,
              payloads[entry.frame.id] == nil else {
            return .needsDurableSpill
        }

        let evictionIDs = evictionPlan(requiredAdditionalBytes: jpegData.count)
        guard let evictionIDs else { return .needsDurableSpill }

        let evictedEntries = removePayloads(ids: Set(evictionIDs)).map(\.entry)
        payloads[entry.frame.id] = Payload(entry: entry, data: jpegData)
        fifoFrameIDs.append(entry.frame.id)
        totalBytes += jpegData.count
        assert(totalBytes <= effectiveByteCap)
        return .inserted(entry: entry, eviction: Eviction(entries: evictedEntries))
    }

    /// Replaces logical metadata with an absolute value while retaining the
    /// immutable payload and FIFO position. This is used only after a proven
    /// promotion/checkpoint so retrying a failed durable operation cannot add
    /// another observation in RAM.
    func reconcile(entry: TimelineEntry) -> TimelineEntry? {
        guard var payload = payloads[entry.frame.id],
              payload.entry.frame.id == entry.frame.id,
              payload.entry.frame.hash == entry.frame.hash,
              payload.entry.frame.displayID == entry.frame.displayID,
              payload.entry.frame.displayName == entry.frame.displayName,
              datesRepresentSameInstant(
                  payload.entry.frame.timestamp,
                  entry.frame.timestamp
              ),
              payload.entry.span.id == entry.span.id,
              payload.entry.span.frameID == entry.span.frameID,
              payload.entry.span.sessionID == entry.span.sessionID,
              datesRepresentSameInstant(
                  payload.entry.span.startedAt,
                  entry.span.startedAt
              ),
              payload.entry.span.displayID == entry.span.displayID,
              entry.span.observedThroughAt >= payload.entry.span.observedThroughAt,
              entry.span.observationCount >= payload.entry.span.observationCount else {
            return nil
        }
        // SQLite stores dates as epoch doubles. Keep the original in-memory
        // frame value so a one-ULP reconstruction difference cannot make the
        // same immutable payload appear to have changed after promotion.
        payload.entry = TimelineEntry(span: entry.span, frame: payload.entry.frame)
        payloads[entry.frame.id] = payload
        return payload.entry
    }

    func extend(
        frameID: UUID,
        observedAt: Date,
        displayName: String?
    ) -> TimelineSpan? {
        guard var payload = payloads[frameID] else { return nil }
        guard observedAt >= payload.entry.span.observedThroughAt else { return nil }
        let span = TimelineSpan(
            id: payload.entry.span.id,
            frameID: payload.entry.span.frameID,
            sessionID: payload.entry.span.sessionID,
            startedAt: payload.entry.span.startedAt,
            observedThroughAt: observedAt,
            observationCount: payload.entry.span.observationCount + 1,
            displayID: payload.entry.span.displayID,
            displayName: displayName ?? payload.entry.span.displayName
        )
        payload.entry = TimelineEntry(span: span, frame: payload.entry.frame)
        payloads[frameID] = payload
        return span
    }

    func entry(frameID: UUID) -> TimelineEntry? {
        payloads[frameID]?.entry
    }

    func data(frameID: UUID) -> Data? {
        payloads[frameID]?.data
    }

    func entries() -> [TimelineEntry] {
        fifoFrameIDs.compactMap { payloads[$0]?.entry }
    }

    func contains(frameID: UUID) -> Bool {
        payloads[frameID] != nil
    }

    func acquireLease(for requestedIDs: Set<UUID>) -> Set<UUID> {
        let leasedIDs = requestedIDs.filter { payloads[$0] != nil }
        for id in leasedIDs {
            leaseCounts[id, default: 0] += 1
        }
        return leasedIDs
    }

    func acquireTimelineSnapshotLease() -> LeasedSnapshot {
        let snapshotEntries = entries()
        let snapshotIDs = Set(snapshotEntries.map(\.frame.id))
        let leasedIDs = acquireLease(for: snapshotIDs)
        assert(leasedIDs == snapshotIDs)
        return LeasedSnapshot(entries: snapshotEntries, leasedFrameIDs: leasedIDs)
    }

    func releaseLease(for leasedIDs: Set<UUID>) -> Maintenance {
        let bytesBefore = totalBytes
        for id in leasedIDs {
            guard let current = leaseCounts[id] else { continue }
            if current <= 1 {
                leaseCounts.removeValue(forKey: id)
            } else {
                leaseCounts[id] = current - 1
            }
        }
        let eviction = trimUnleased(toByteCount: effectiveByteCap)
        return Maintenance(
            eviction: eviction,
            bytesBefore: bytesBefore,
            bytesAfter: totalBytes,
            targetBytes: effectiveByteCap
        )
    }

    func removeSpans(ids: Set<UUID>) -> Eviction {
        let frameIDs = Set(fifoFrameIDs.filter { id in
            guard let entry = payloads[id]?.entry else { return false }
            return ids.contains(entry.span.id)
        })
        return Eviction(entries: removePayloads(ids: frameIDs).map(\.entry))
    }

    func clear() -> Eviction {
        let removed = fifoFrameIDs.compactMap { payloads[$0]?.entry }
        payloads.removeAll(keepingCapacity: false)
        fifoFrameIDs.removeAll(keepingCapacity: false)
        leaseCounts.removeAll(keepingCapacity: false)
        totalBytes = 0
        return Eviction(entries: removed)
    }

    /// A warning permanently lowers this launch's RAM admission ceiling to a
    /// quarter of the configured value. Leased payloads remain pinned; their
    /// eventual release runs the same trim before the caller resumes capture.
    func reduceForWarning() -> Maintenance {
        let bytesBefore = totalBytes
        effectiveByteCap = min(effectiveByteCap, configuredByteCap / 4)
        let eviction = trimUnleased(toByteCount: effectiveByteCap)
        return Maintenance(
            eviction: eviction,
            bytesBefore: bytesBefore,
            bytesAfter: totalBytes,
            targetBytes: effectiveByteCap
        )
    }

    /// Critical pressure disables volatile admission for the rest of this
    /// launch and drops every unleased payload. AppDelegate first releases the
    /// known overlay snapshot; any unknown defensive lease remains valid and
    /// its release completes the deferred zero-cap trim.
    func dropAllForCriticalPressure() -> Maintenance {
        let bytesBefore = totalBytes
        effectiveByteCap = 0
        let eviction = trimUnleased(toByteCount: 0)
        return Maintenance(
            eviction: eviction,
            bytesBefore: bytesBefore,
            bytesAfter: totalBytes,
            targetBytes: 0
        )
    }

    func statistics() -> Statistics {
        let entries = payloads.values.map(\.entry)
        let bounds = entries.map(timelineSpanBounds(for:))
        return Statistics(
            totalBytes: totalBytes,
            byteCap: effectiveByteCap,
            configuredByteCap: configuredByteCap,
            payloadCount: payloads.count,
            spanCount: entries.count,
            observationCount: entries.reduce(0) { $0 + $1.span.observationCount },
            coverageStart: bounds.map(\.start).min(),
            coverageEnd: bounds.map(\.end).max()
        )
    }

    private func evictionPlan(requiredAdditionalBytes: Int) -> [UUID]? {
        guard requiredAdditionalBytes <= effectiveByteCap else { return nil }
        var projectedBytes = totalBytes
        var candidates: [UUID] = []
        for id in fifoFrameIDs where projectedBytes + requiredAdditionalBytes > effectiveByteCap {
            guard leaseCounts[id] == nil, let payload = payloads[id] else { continue }
            candidates.append(id)
            projectedBytes -= payload.data.count
        }
        return projectedBytes + requiredAdditionalBytes <= effectiveByteCap ? candidates : nil
    }

    private func trimUnleased(toByteCount target: Int) -> Eviction {
        var removalIDs = Set<UUID>()
        var projectedBytes = totalBytes
        for id in fifoFrameIDs where projectedBytes > target {
            guard leaseCounts[id] == nil, let payload = payloads[id] else { continue }
            removalIDs.insert(id)
            projectedBytes -= payload.data.count
        }
        return Eviction(entries: removePayloads(ids: removalIDs).map(\.entry))
    }

    /// Removes a batch in one FIFO pass. Critical-pressure and multi-span
    /// pruning therefore remain linear in the number of resident payloads.
    private func removePayloads(ids: Set<UUID>) -> [Payload] {
        guard !ids.isEmpty else { return [] }
        var removed: [Payload] = []
        var retainedIDs: [UUID] = []
        retainedIDs.reserveCapacity(max(0, fifoFrameIDs.count - ids.count))
        for id in fifoFrameIDs {
            guard ids.contains(id), let payload = payloads.removeValue(forKey: id) else {
                retainedIDs.append(id)
                continue
            }
            removed.append(payload)
            totalBytes -= payload.data.count
            leaseCounts.removeValue(forKey: id)
        }
        fifoFrameIDs = retainedIDs
        return removed
    }

    private func removePayload(id: UUID) -> Payload? {
        guard let removed = payloads.removeValue(forKey: id) else { return nil }
        fifoFrameIDs.removeAll { $0 == id }
        totalBytes -= removed.data.count
        leaseCounts.removeValue(forKey: id)
        return removed
    }

    private func datesRepresentSameInstant(_ lhs: Date, _ rhs: Date) -> Bool {
        let lhsValue = lhs.timeIntervalSince1970
        let rhsValue = rhs.timeIntervalSince1970
        if lhsValue == rhsValue { return true }
        let tolerance = max(lhsValue.ulp, rhsValue.ulp) * 2
        return abs(lhsValue - rhsValue) <= tolerance
    }
}
