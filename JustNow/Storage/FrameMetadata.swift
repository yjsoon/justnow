//
//  FrameMetadata.swift
//  JustNow
//

import Foundation

nonisolated struct FrameMetadata: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let hash: UInt64
    let filename: String
    let thumbnailFilename: String
    let fileSize: Int64
    /// Stable display identifier. Nil for frames captured before multi-display support;
    /// treated as belonging to the primary display when surfaced.
    let displayID: UUID?
    /// Friendly name snapshotted at capture time, so the overlay can label
    /// frames from a display that is no longer connected.
    let displayName: String?
}

nonisolated enum CaptureSessionEndReason: String, Sendable, Codable {
    case paused
    case sleep
    case screenSleep
    case screenLock
    case sessionInactive
    case overlay
    case unexpectedStop
    case termination
    case cleared
    case interrupted
    case legacyMigration
    case directStore
}

nonisolated struct CaptureSession: Identifiable, Sendable, Equatable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date?
    let endReason: CaptureSessionEndReason?
}

/// A durable lower-bound interval during which the encoded JPEG was observed
/// to remain byte-for-byte identical. Gaps between spans are intentionally not
/// filled because no persisted observation proves what was displayed there.
nonisolated struct TimelineSpan: Identifiable, Sendable, Equatable {
    let id: UUID
    let frameID: UUID
    let sessionID: UUID
    let startedAt: Date
    let observedThroughAt: Date
    let observationCount: Int
    let displayID: UUID?
    let displayName: String?
}

nonisolated struct TimelineEntry: Identifiable, Sendable, Equatable {
    let span: TimelineSpan
    let frame: StoredFrame

    var id: UUID { span.id }
}

nonisolated struct TimelineSpanBounds: Equatable {
    let start: Date
    let end: Date
}

nonisolated struct FrameCoverageIntervalStatistics: Sendable, Equatable {
    let oldest: Date?
    let newest: Date?
    let coveredSeconds: TimeInterval
    let hasGaps: Bool

    static let empty = Self(oldest: nil, newest: nil, coveredSeconds: 0, hasGaps: false)
}

nonisolated struct FrameDisplayCoverageStatistics: Sendable, Equatable, Identifiable {
    let displayID: UUID?
    let displayName: String?
    let durable: FrameCoverageIntervalStatistics
    let volatile: FrameCoverageIntervalStatistics
    let combined: FrameCoverageIntervalStatistics

    var id: String { displayID?.uuidString ?? "legacy" }
    var displayLabel: String { displayID == nil ? "Legacy history" : (displayName ?? "Display") }
}

/// Calculates real covered time rather than subtracting the oldest timestamp
/// from the newest. Each source is unioned independently and mirrored spans
/// are unioned again for the combined value, so overlap is never double-counted.
nonisolated enum FrameCoverageCalculator {
    private enum DisplayKey: Hashable {
        case legacy
        case identified(UUID)

        init(_ displayID: UUID?) {
            self = displayID.map(Self.identified) ?? .legacy
        }

        var displayID: UUID? {
            switch self {
            case .legacy: nil
            case .identified(let id): id
            }
        }
    }

    private struct NamedEntry {
        let entry: TimelineEntry
        let bounds: TimelineSpanBounds
    }

    static func calculate(
        durable durableEntries: [TimelineEntry],
        volatile volatileEntries: [TimelineEntry],
        combined combinedEntries: [TimelineEntry]? = nil
    ) -> [FrameDisplayCoverageStatistics] {
        let durable = Dictionary(grouping: durableEntries) { DisplayKey($0.span.displayID) }
        let volatile = Dictionary(grouping: volatileEntries) { DisplayKey($0.span.displayID) }
        let combinedValues = combinedEntries ?? (durableEntries + volatileEntries)
        let combined = Dictionary(grouping: combinedValues) { DisplayKey($0.span.displayID) }
        let keys = Set(durable.keys).union(volatile.keys).union(combined.keys)

        return keys.map { key in
            let durableValues = durable[key] ?? []
            let volatileValues = volatile[key] ?? []
            let allValues = combined[key] ?? []
            let named = allValues.map { NamedEntry(entry: $0, bounds: timelineSpanBounds(for: $0)) }
                .sorted { lhs, rhs in
                    if lhs.bounds.end != rhs.bounds.end { return lhs.bounds.end > rhs.bounds.end }
                    return lhs.entry.span.id.uuidString < rhs.entry.span.id.uuidString
                }
            let displayName = named.lazy.compactMap {
                $0.entry.span.displayName ?? $0.entry.frame.displayName
            }.first

            return FrameDisplayCoverageStatistics(
                displayID: key.displayID,
                displayName: displayName,
                durable: intervalStatistics(for: durableValues),
                volatile: intervalStatistics(for: volatileValues),
                combined: intervalStatistics(for: allValues)
            )
        }.sorted { lhs, rhs in
            if lhs.displayID == nil { return false }
            if rhs.displayID == nil { return true }
            if lhs.displayLabel != rhs.displayLabel { return lhs.displayLabel < rhs.displayLabel }
            return lhs.id < rhs.id
        }
    }

    static func intervalStatistics(
        for entries: [TimelineEntry]
    ) -> FrameCoverageIntervalStatistics {
        let sorted = entries.map(timelineSpanBounds(for:)).sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.end < rhs.end
        }
        guard var current = sorted.first else { return .empty }

        var merged: [TimelineSpanBounds] = []
        for interval in sorted.dropFirst() {
            if interval.start <= current.end {
                current = TimelineSpanBounds(start: current.start, end: max(current.end, interval.end))
            } else {
                merged.append(current)
                current = interval
            }
        }
        merged.append(current)

        return FrameCoverageIntervalStatistics(
            oldest: merged.first?.start,
            newest: merged.last?.end,
            coveredSeconds: merged.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) },
            hasGaps: merged.count > 1
        )
    }
}

/// Durable spans normally advance monotonically, but imported data and wall
/// clock adjustments can produce a reversed pair. All browsing, filtering,
/// and search boundaries use this normalised interval.
nonisolated func timelineSpanBounds(for entry: TimelineEntry) -> TimelineSpanBounds {
    TimelineSpanBounds(
        start: min(entry.span.startedAt, entry.span.observedThroughAt),
        end: max(entry.span.startedAt, entry.span.observedThroughAt)
    )
}

/// Read-only compatibility model for importing pre-SQLite `manifest.json`
/// stores. New captures never write this format.
nonisolated struct FrameManifest: Codable, Sendable {
    var version: Int = 2
    var frames: [FrameMetadata] = []
    var lastModified: Date = Date()
}

nonisolated struct FrameStorageStatistics: Sendable, Equatable {
    /// Durable bytes currently retained on disk. This deliberately excludes
    /// volatile RAM history so callers do not mistake memory use for storage
    /// or NAND activity.
    let storedBytes: Int64
    /// Number of unique physical JPEG payloads.
    let frameCount: Int
    /// Unique physical JPEG payloads backed by the durable store. In an
    /// all-disk repository this equals `frameCount`; hybrid repositories also
    /// expose `volatileFrameCount` separately.
    let durableFrameCount: Int
    /// Number of logical timeline spans referencing those payloads.
    let timelineSpanCount: Int
    /// Number of accepted observations represented by all spans.
    let observationCount: Int
    let projectionSamples: [FrameStorageSample]
    /// Encoded JPEG bytes retained only in the launch-scoped RAM ring.
    let volatileBytes: Int64
    /// The global byte budget for volatile history. Zero means no RAM source.
    let volatileByteCap: Int64
    /// The launch-configured byte budget before any memory-pressure reduction.
    let configuredVolatileByteCap: Int64
    /// Unique volatile physical JPEG payloads.
    let volatileFrameCount: Int
    /// Logical volatile spans currently covered by the RAM ring.
    let volatileTimelineSpanCount: Int
    /// Accepted observations represented by volatile spans.
    let volatileObservationCount: Int
    /// Bounds of the volatile timeline currently retained in RAM. These are
    /// bounds rather than a promise of continuous history: normal capture
    /// gaps and evictions remain visible as gaps between logical spans.
    let volatileCoverageStart: Date?
    let volatileCoverageEnd: Date?
    /// Per-display interval unions for durable, RAM, and source-coalesced history.
    let displayCoverage: [FrameDisplayCoverageStatistics]

    init(
        storedBytes: Int64,
        frameCount: Int,
        durableFrameCount: Int? = nil,
        timelineSpanCount: Int? = nil,
        observationCount: Int? = nil,
        projectionSamples: [FrameStorageSample],
        volatileBytes: Int64 = 0,
        volatileByteCap: Int64 = 0,
        configuredVolatileByteCap: Int64? = nil,
        volatileFrameCount: Int = 0,
        volatileTimelineSpanCount: Int = 0,
        volatileObservationCount: Int = 0,
        volatileCoverageStart: Date? = nil,
        volatileCoverageEnd: Date? = nil,
        displayCoverage: [FrameDisplayCoverageStatistics] = []
    ) {
        self.storedBytes = storedBytes
        self.frameCount = frameCount
        self.durableFrameCount = durableFrameCount ?? frameCount
        self.timelineSpanCount = timelineSpanCount ?? frameCount
        self.observationCount = observationCount ?? frameCount
        self.projectionSamples = projectionSamples
        self.volatileBytes = volatileBytes
        self.volatileByteCap = volatileByteCap
        self.configuredVolatileByteCap = configuredVolatileByteCap ?? volatileByteCap
        self.volatileFrameCount = volatileFrameCount
        self.volatileTimelineSpanCount = volatileTimelineSpanCount
        self.volatileObservationCount = volatileObservationCount
        self.volatileCoverageStart = volatileCoverageStart
        self.volatileCoverageEnd = volatileCoverageEnd
        self.displayCoverage = displayCoverage
    }

    static let empty = FrameStorageStatistics(
        storedBytes: 0,
        frameCount: 0,
        timelineSpanCount: 0,
        observationCount: 0,
        projectionSamples: []
    )
}

nonisolated struct FrameStorageSample: Sendable, Equatable {
    let displayID: UUID?
    let storedBytes: Int64
    let frameCount: Int
}
