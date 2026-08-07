//
//  FrameDatabase.swift
//  JustNow
//

import Foundation
import SQLite3

enum FrameDatabaseError: Error {
    case sqlite(String)
    case corrupt(String)
    case unsupportedSchema(Int)
    case activeCaptureSession(UUID)
    case captureSessionNotFound(UUID)
    case captureSessionMismatch(expected: UUID, active: UUID?)
    case invalidPromotion(String)
    case promotionConflict(String)
}

typealias FrameDatabaseCommitHook = @Sendable (DurablePersistenceOperation) throws -> Void

/// SQLite metadata store confined to `FrameStore`'s actor. Full-size images
/// and thumbnails deliberately remain ordinary files under `frames/`.
nonisolated final class FrameDatabase: @unchecked Sendable {
    private enum DurablePlan {
        case insert
        case checkpoint
        case noOp(TimelineEntry)
    }

    private struct ColumnDefinition: Equatable {
        let name: String
        let type: String
        let notNull: Int32
        let primaryKeyPosition: Int32
    }

    private struct IndexColumn: Equatable {
        let name: String
        let descending: Int32
    }

    static let schemaVersion = 2
    static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    let url: URL
    private var db: OpaquePointer?
    private let durableCommitHook: FrameDatabaseCommitHook?

    init(url: URL, durableCommitHook: FrameDatabaseCommitHook? = nil) throws {
        self.url = url
        self.durableCommitHook = durableCommitHook

        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &connection, flags, nil) == SQLITE_OK,
              let connection else {
            defer {
                if let connection {
                    sqlite3_close(connection)
                }
            }
            throw Self.sqliteError(message: "Failed to open frame database", on: connection)
        }

        db = connection
        do {
            sqlite3_busy_timeout(connection, 5_000)
            try execute("PRAGMA journal_mode=WAL;")
            // NORMAL avoids an fsync for every high-frequency capture. WAL
            // remains consistent after a crash, but the latest committed
            // metadata transaction can be lost on a sudden power failure;
            // startup orphan recovery preserves the corresponding JPEG.
            try execute("PRAGMA synchronous=NORMAL;")
            try execute("PRAGMA foreign_keys=ON;")
            try execute("PRAGMA temp_store=MEMORY;")
            try validateOrCreateSchema()
            try quickCheck()
            try closeInterruptedSession()
        } catch {
            close()
            throw error
        }
    }

    deinit {
        close()
    }

    func close() {
        guard let db else { return }
        sqlite3_close(db)
        self.db = nil
    }

    func checkpoint() throws {
        try withPreparedStatement("PRAGMA wal_checkpoint(FULL);") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw sqliteError(message: "Failed to checkpoint frame database")
            }
            let busy = sqlite3_column_int(statement, 0)
            let logFrames = sqlite3_column_int(statement, 1)
            let checkpointedFrames = sqlite3_column_int(statement, 2)
            guard busy == 0, checkpointedFrames >= logFrames else {
                throw FrameDatabaseError.sqlite(
                    "Frame database checkpoint incomplete " +
                        "(busy=\(busy), log=\(logFrames), checkpointed=\(checkpointedFrames))"
                )
            }
            try requireDone(statement, message: "Failed to finish frame database checkpoint")
        }
    }

    func configuredSynchronousMode() throws -> Int {
        try pragmaInt("PRAGMA synchronous;")
    }

    func configuredBusyTimeout() throws -> Int {
        try pragmaInt("PRAGMA busy_timeout;")
    }

    func quickCheck() throws {
        try withPreparedStatement("PRAGMA quick_check(1);") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let text = sqlite3_column_text(statement, 0),
                  String(cString: text) == "ok" else {
                throw FrameDatabaseError.corrupt("SQLite quick check failed")
            }
            try requireDone(statement, message: "Failed to finish SQLite quick check")
        }
    }

    var storeID: String {
        get throws {
            if let existing = try metadataValue(for: "store_id"), !existing.isEmpty {
                return existing
            }
            let generated = UUID().uuidString
            try setMetadataValue(generated, for: "store_id")
            return generated
        }
    }

    func metadataValue(for key: String) throws -> String? {
        try withPreparedStatement("SELECT value FROM store_meta WHERE key = ? LIMIT 1;") { statement in
            guard bindText(key, to: statement, index: 1) else {
                throw sqliteError(message: "Failed to bind metadata key")
            }
            switch sqlite3_step(statement) {
            case SQLITE_DONE:
                return nil
            case SQLITE_ROW:
                guard let text = sqlite3_column_text(statement, 0) else {
                    throw FrameDatabaseError.corrupt("Invalid store metadata value")
                }
                let value = String(cString: text)
                try requireDone(statement, message: "Failed to finish reading store metadata")
                return value
            default:
                throw sqliteError(message: "Failed to read store metadata")
            }
        }
    }

    func setMetadataValue(_ value: String, for key: String) throws {
        try withPreparedStatement(
            "INSERT INTO store_meta(key, value) VALUES (?, ?) " +
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value;"
        ) { statement in
            guard bindText(key, to: statement, index: 1),
                  bindText(value, to: statement, index: 2),
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteError(message: "Failed to write store metadata")
            }
        }
    }

    func frameCount() throws -> Int {
        try withPreparedStatement("SELECT COUNT(*) FROM frames;") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw sqliteError(message: "Failed to count frames")
            }
            let count = Int(sqlite3_column_int64(statement, 0))
            try requireDone(statement, message: "Failed to finish counting frames")
            return count
        }
    }

    func metadata(for id: UUID) throws -> FrameMetadata? {
        try withPreparedStatement(
            """
            SELECT id, captured_at, perceptual_hash, filename,
                   thumbnail_filename, file_size, display_id, display_name
            FROM frames
            WHERE id = ?
            LIMIT 1;
            """
        ) { statement in
            guard bindText(id.uuidString, to: statement, index: 1) else {
                throw sqliteError(message: "Failed to bind frame ID")
            }
            switch sqlite3_step(statement) {
            case SQLITE_DONE:
                return nil
            case SQLITE_ROW:
                let metadata = try decodeMetadata(from: statement)
                try requireDone(statement, message: "Failed to finish reading frame metadata")
                return metadata
            default:
                throw sqliteError(message: "Failed to read frame metadata")
            }
        }
    }

    func allMetadata() throws -> [FrameMetadata] {
        try withPreparedStatement(
            """
            SELECT id, captured_at, perceptual_hash, filename,
                   thumbnail_filename, file_size, display_id, display_name
            FROM frames
            ORDER BY captured_at ASC, sequence ASC;
            """
        ) { statement in
            var rows: [FrameMetadata] = []
            var filenames = Set<String>()
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                let metadata = try decodeMetadata(from: statement)
                guard filenames.insert(FrameStoreFilename.collisionKey(metadata.filename)).inserted,
                      filenames.insert(FrameStoreFilename.collisionKey(metadata.thumbnailFilename)).inserted else {
                    throw FrameDatabaseError.corrupt(
                        "Duplicate or cross-colliding frame filename in frame database"
                    )
                }
                rows.append(metadata)
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else {
                throw sqliteError(message: "Failed to finish reading frame metadata")
            }
            return rows
        }
    }

    func allTimelineEntries() throws -> [TimelineEntry] {
        try timelineEntries(
            sql:
                """
                SELECT spans.id, spans.frame_id, spans.session_id,
                       spans.started_at, spans.observed_through_at,
                       spans.observation_count, spans.display_id, spans.display_name,
                       frames.id, frames.captured_at, frames.perceptual_hash,
                       frames.filename, frames.thumbnail_filename, frames.file_size,
                       frames.display_id, frames.display_name
                FROM frame_spans AS spans
                JOIN frames ON frames.id = spans.frame_id
                ORDER BY spans.started_at ASC, spans.sequence ASC;
                """
        )
    }

    func activeTimelineEntry(displayID: UUID?) throws -> TimelineEntry? {
        let entries = try timelineEntries(
            sql:
                """
                SELECT spans.id, spans.frame_id, spans.session_id,
                       spans.started_at, spans.observed_through_at,
                       spans.observation_count, spans.display_id, spans.display_name,
                       frames.id, frames.captured_at, frames.perceptual_hash,
                       frames.filename, frames.thumbnail_filename, frames.file_size,
                       frames.display_id, frames.display_name
                FROM frame_spans AS spans
                JOIN capture_sessions AS sessions ON sessions.id = spans.session_id
                JOIN frames ON frames.id = spans.frame_id
                WHERE sessions.ended_at IS NULL AND spans.display_id IS ?
                ORDER BY spans.sequence DESC
                LIMIT 1;
                """,
            bind: { statement in
                guard self.bindOptionalText(displayID?.uuidString, to: statement, index: 1) else {
                    throw self.sqliteError(message: "Failed to bind active-span display ID")
                }
            }
        )
        return entries.first
    }

    func activeSession() throws -> CaptureSession? {
        try withPreparedStatement(
            """
            SELECT id, started_at, ended_at, end_reason
            FROM capture_sessions
            WHERE ended_at IS NULL
            ORDER BY sequence DESC
            LIMIT 1;
            """
        ) { statement in
            switch sqlite3_step(statement) {
            case SQLITE_DONE:
                return nil
            case SQLITE_ROW:
                let session = try decodeSession(from: statement)
                try requireDone(statement, message: "Failed to finish reading active capture session")
                return session
            default:
                throw sqliteError(message: "Failed to read active capture session")
            }
        }
    }

    func beginCaptureSession(at startedAt: Date) throws -> CaptureSession {
        guard startedAt.timeIntervalSince1970.isFinite else {
            throw FrameDatabaseError.corrupt("Invalid capture session start timestamp")
        }
        if let active = try activeSession() {
            throw FrameDatabaseError.activeCaptureSession(active.id)
        }

        let session = CaptureSession(
            id: UUID(),
            startedAt: startedAt,
            endedAt: nil,
            endReason: nil
        )
        try withTransaction {
            try insertSession(session)
        }
        return session
    }

    func endCaptureSession(id: UUID, reason: CaptureSessionEndReason) throws {
        guard let session = try session(for: id) else {
            throw FrameDatabaseError.captureSessionNotFound(id)
        }
        // Retried closes are idempotent, including the case where SQLite
        // committed but a higher layer reported an error afterward.
        guard session.endedAt == nil else { return }
        let activeID = try activeSession()?.id
        guard activeID == id else {
            throw FrameDatabaseError.captureSessionMismatch(expected: id, active: activeID)
        }
        let endedAt = try withPreparedStatement(
            """
            SELECT COALESCE(MAX(observed_through_at), ?)
            FROM frame_spans
            WHERE session_id = ?;
            """
        ) { statement -> Date in
            guard sqlite3_bind_double(statement, 1, session.startedAt.timeIntervalSince1970) == SQLITE_OK,
                  bindText(session.id.uuidString, to: statement, index: 2),
                  sqlite3_step(statement) == SQLITE_ROW else {
                throw sqliteError(message: "Failed to calculate capture session end")
            }
            let value = sqlite3_column_double(statement, 0)
            guard value.isFinite else {
                throw FrameDatabaseError.corrupt("Invalid capture session end timestamp")
            }
            try requireDone(statement, message: "Failed to finish calculating capture session end")
            return max(Date(timeIntervalSince1970: value), session.startedAt)
        }

        try withPreparedStatement(
            "UPDATE capture_sessions SET ended_at = ?, end_reason = ? WHERE id = ? AND ended_at IS NULL;"
        ) { statement in
            guard sqlite3_bind_double(statement, 1, endedAt.timeIntervalSince1970) == SQLITE_OK,
                  bindText(reason.rawValue, to: statement, index: 2),
                  bindText(session.id.uuidString, to: statement, index: 3),
                  sqlite3_step(statement) == SQLITE_DONE,
                  sqlite3_changes(db) == 1 else {
                throw sqliteError(message: "Failed to end capture session")
            }
        }
    }

    func insertCapture(
        _ metadata: FrameMetadata,
        spanID: UUID,
        sessionID: UUID
    ) throws -> TimelineEntry {
        let span = TimelineSpan(
            id: spanID,
            frameID: metadata.id,
            sessionID: sessionID,
            startedAt: metadata.timestamp,
            observedThroughAt: metadata.timestamp,
            observationCount: 1,
            displayID: metadata.displayID,
            displayName: metadata.displayName
        )
        try withTransaction {
            guard try activeSession()?.id == sessionID else {
                throw FrameDatabaseError.corrupt("Capture insert has no matching active session")
            }
            try insertRow(metadata, preservingSequence: nil)
            try insertSpan(span, preservingSequence: nil)
        }
        return TimelineEntry(span: span, frame: storedFrame(from: metadata))
    }

    func extendSpan(id: UUID, observedAt: Date, displayName: String?) throws -> TimelineSpan {
        guard observedAt.timeIntervalSince1970.isFinite else {
            throw FrameDatabaseError.corrupt("Invalid span observation timestamp")
        }
        try withTransaction {
            try withPreparedStatement(
                """
                UPDATE frame_spans
                SET observed_through_at = ?, observation_count = observation_count + 1,
                    display_name = COALESCE(?, display_name)
                WHERE id = ? AND observed_through_at <= ?;
                """
            ) { statement in
                guard sqlite3_bind_double(statement, 1, observedAt.timeIntervalSince1970) == SQLITE_OK,
                      bindOptionalText(displayName, to: statement, index: 2),
                      bindText(id.uuidString, to: statement, index: 3),
                      sqlite3_bind_double(statement, 4, observedAt.timeIntervalSince1970) == SQLITE_OK,
                      sqlite3_step(statement) == SQLITE_DONE,
                      sqlite3_changes(db) == 1 else {
                    throw FrameDatabaseError.corrupt("Span extension was stale or missing")
                }
            }
        }
        guard let span = try span(for: id) else {
            throw FrameDatabaseError.corrupt("Extended span disappeared")
        }
        return span
    }

    /// A direct durable lookup of the joined frame/span identity. Callers use
    /// this as the commit witness after an ambiguous SQLite error; filenames
    /// are never treated as proof that metadata committed.
    func durableEntry(frameID: UUID, spanID: UUID) throws -> TimelineEntry? {
        try timelineEntries(
            sql:
                """
                SELECT spans.id, spans.frame_id, spans.session_id,
                       spans.started_at, spans.observed_through_at,
                       spans.observation_count, spans.display_id, spans.display_name,
                       frames.id, frames.captured_at, frames.perceptual_hash,
                       frames.filename, frames.thumbnail_filename, frames.file_size,
                       frames.display_id, frames.display_name
                FROM frame_spans AS spans
                JOIN frames ON frames.id = spans.frame_id
                WHERE spans.id = ? AND frames.id = ?
                LIMIT 1;
                """,
            bind: { statement in
                guard self.bindText(spanID.uuidString, to: statement, index: 1),
                      self.bindText(frameID.uuidString, to: statement, index: 2) else {
                    throw self.sqliteError(message: "Failed to bind durable entry identity")
                }
            }
        ).first
    }

    /// Read-only preflight used before FrameStore creates a JPEG. The same
    /// checks run again at the transaction boundary.
    func validateVolatileEntryForPromotion(
        _ entry: TimelineEntry,
        metadata: FrameMetadata
    ) throws {
        _ = try promotionPlan(for: entry, metadata: metadata)
    }

    func promoteVolatileEntry(
        _ entry: TimelineEntry,
        metadata: FrameMetadata
    ) throws -> DurablePersistenceResult {
        switch try promotionPlan(for: entry, metadata: metadata) {
        case .insert:
            try withTransaction(operation: .promotion) {
                guard case .insert = try promotionPlan(for: entry, metadata: metadata) else {
                    throw FrameDatabaseError.promotionConflict(
                        "Promotion state changed before insertion"
                    )
                }
                try insertRow(metadata, preservingSequence: nil)
                try insertSpan(entry.span, preservingSequence: nil)
            }
            guard let committed = try durableEntry(frameID: entry.frame.id, spanID: entry.span.id) else {
                throw FrameDatabaseError.corrupt("Promoted entry disappeared after insertion")
            }
            return DurablePersistenceResult(
                effect: .inserted,
                entry: committed,
                wroteDurableJPEG: false,
                logicalMetadataByteCount: Self.logicalByteCount(for: committed)
            )

        case .checkpoint:
            try withTransaction(operation: .promotion) {
                try updatePromotedSpanAbsolute(entry.span)
            }
            guard let committed = try durableEntry(frameID: entry.frame.id, spanID: entry.span.id) else {
                throw FrameDatabaseError.corrupt("Promoted entry disappeared after reconciliation")
            }
            return DurablePersistenceResult(
                effect: .checkpointed,
                entry: committed,
                wroteDurableJPEG: false,
                logicalMetadataByteCount: Self.logicalByteCount(for: committed.span)
            )

        case .noOp(let committed):
            return DurablePersistenceResult(
                effect: .noOp,
                entry: committed,
                wroteDurableJPEG: false,
                logicalMetadataByteCount: 0
            )
        }
    }

    func checkpointPromotedSpan(_ requested: TimelineSpan) throws -> DurablePersistenceResult {
        let plan = try checkpointPlan(for: requested)
        switch plan {
        case .checkpoint:
            try withTransaction(operation: .checkpoint) {
                guard case .checkpoint = try checkpointPlan(for: requested) else {
                    throw FrameDatabaseError.promotionConflict(
                        "Checkpoint state changed before update"
                    )
                }
                try updatePromotedSpanAbsolute(requested)
            }
            guard let committed = try durableEntry(frameID: requested.frameID, spanID: requested.id) else {
                throw FrameDatabaseError.corrupt("Checkpointed entry disappeared after update")
            }
            return DurablePersistenceResult(
                effect: .checkpointed,
                entry: committed,
                wroteDurableJPEG: false,
                logicalMetadataByteCount: Self.logicalByteCount(for: committed.span)
            )

        case .noOp(let committed):
            return DurablePersistenceResult(
                effect: .noOp,
                entry: committed,
                wroteDurableJPEG: false,
                logicalMetadataByteCount: 0
            )

        case .insert:
            throw FrameDatabaseError.promotionConflict("Checkpoint target is not durable")
        }
    }

    func insert(_ metadata: FrameMetadata) throws {
        let session = try activeSession() ?? beginCaptureSession(at: metadata.timestamp)
        _ = try insertCapture(metadata, spanID: metadata.id, sessionID: session.id)
    }

    func importLegacyFrames(
        _ frames: [FrameMetadata],
        fingerprint: String,
        backupFilename: String
    ) throws {
        try withTransaction {
            let legacySessionID = UUID()
            if let first = frames.first {
                let startedAt = frames.map(\.timestamp).min() ?? first.timestamp
                let endedAt = frames.map(\.timestamp).max() ?? first.timestamp
                try insertSession(
                    CaptureSession(
                        id: legacySessionID,
                        startedAt: startedAt,
                        endedAt: endedAt,
                        endReason: .legacyMigration
                    )
                )
            }
            for (offset, frame) in frames.enumerated() {
                try insertRow(frame, preservingSequence: Int64(offset + 1))
                try insertSpan(
                    TimelineSpan(
                        id: frame.id,
                        frameID: frame.id,
                        sessionID: legacySessionID,
                        startedAt: frame.timestamp,
                        observedThroughAt: frame.timestamp,
                        observationCount: 1,
                        displayID: frame.displayID,
                        displayName: frame.displayName
                    ),
                    preservingSequence: Int64(offset + 1)
                )
            }
            try setMetadataValue(fingerprint, for: "legacy_manifest_fingerprint")
            try setMetadataValue(String(frames.count), for: "legacy_manifest_count")
            try setMetadataValue("complete", for: "legacy_manifest_migration_state")
            try setMetadataValue(backupFilename, for: "legacy_manifest_backup_filename")
            try setMetadataValue("0", for: "legacy_manifest_healthy_launches")
        }
    }

    func deleteFrames(ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        try withTransaction {
            try deleteRows(table: "frame_spans", column: "frame_id", ids: ids)
            let values = Array(ids)
            for start in stride(from: 0, to: values.count, by: 400) {
                let end = min(start + 400, values.count)
                let chunk = Array(values[start..<end])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try withPreparedStatement("DELETE FROM frames WHERE id IN (\(placeholders));") { statement in
                    for (offset, id) in chunk.enumerated() {
                        guard bindText(id.uuidString, to: statement, index: Int32(offset + 1)) else {
                            throw sqliteError(message: "Failed to bind frame ID for deletion")
                        }
                    }
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw sqliteError(message: "Failed to delete frame rows")
                    }
                }
            }
        }
    }

    /// Deletes logical spans, returning only physical payloads that no longer
    /// have any references and were therefore removed from `frames` as well.
    func deleteSpans(ids: Set<UUID>) throws -> [FrameMetadata] {
        guard !ids.isEmpty else { return [] }
        var removedAssets: [FrameMetadata] = []
        try withTransaction {
            let referencedFrameIDs = try frameIDs(forSpanIDs: ids)
            try deleteRows(table: "frame_spans", column: "id", ids: ids)
            for frameID in referencedFrameIDs where try spanReferenceCount(frameID: frameID) == 0 {
                if let metadata = try metadata(for: frameID) {
                    removedAssets.append(metadata)
                }
                try deleteRows(table: "frames", column: "id", ids: Set([frameID]))
            }
        }
        return removedAssets
    }

    func deleteAllFrames() throws {
        try withTransaction {
            try execute("DELETE FROM frame_spans;")
            try execute("DELETE FROM frames;")
            try execute("DELETE FROM capture_sessions;")
        }
    }

    func storageStatistics(
        sampleLimitPerDisplay: Int,
        logicalOverlay: [TimelineEntry] = []
    ) throws -> FrameStorageStatistics {
        let totals = try withPreparedStatement(
            """
            SELECT COALESCE(SUM(file_size), 0), COUNT(*),
                   (SELECT COUNT(*) FROM frame_spans),
                   (SELECT COALESCE(SUM(observation_count), 0) FROM frame_spans)
            FROM frames;
            """
        ) { statement -> (Int64, Int, Int, Int) in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw sqliteError(message: "Failed to calculate frame storage totals")
            }
            let totals = (
                sqlite3_column_int64(statement, 0),
                Int(sqlite3_column_int64(statement, 1)),
                Int(sqlite3_column_int64(statement, 2)),
                Int(sqlite3_column_int64(statement, 3))
            )
            try requireDone(statement, message: "Failed to finish calculating frame storage totals")
            return totals
        }

        let samples = try withPreparedStatement(
            """
            WITH ranked AS (
                SELECT display_id, file_size,
                       ROW_NUMBER() OVER (
                           PARTITION BY display_id
                           ORDER BY captured_at DESC, sequence DESC
                       ) AS sample_rank
                FROM frames
            )
            SELECT display_id, COALESCE(SUM(file_size), 0), COUNT(*)
            FROM ranked
            WHERE sample_rank <= ?
            GROUP BY display_id;
            """
        ) { statement -> [FrameStorageSample] in
            guard sqlite3_bind_int(statement, 1, Int32(clamping: sampleLimitPerDisplay)) == SQLITE_OK else {
                throw sqliteError(message: "Failed to bind projection sample limit")
            }

            var values: [FrameStorageSample] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                let displayID: UUID?
                if sqlite3_column_type(statement, 0) == SQLITE_NULL {
                    displayID = nil
                } else {
                    guard let text = sqlite3_column_text(statement, 0),
                          let decoded = UUID(uuidString: String(cString: text)) else {
                        throw FrameDatabaseError.corrupt("Invalid display ID in frame database")
                    }
                    displayID = decoded
                }
                values.append(
                    FrameStorageSample(
                        displayID: displayID,
                        jpegPayloadBytes: sqlite3_column_int64(statement, 1),
                        frameCount: Int(sqlite3_column_int64(statement, 2))
                    )
                )
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else {
                throw sqliteError(message: "Failed to finish reading frame storage samples")
            }
            return values
        }

        // Merge durable span intervals inside SQLite and return one bounded
        // aggregate per display. Settings never needs to materialise the
        // complete durable timeline merely to show coverage totals.
        let displayCoverage = try withPreparedStatement(
            """
            WITH ordered AS (
                SELECT display_id, display_name, sequence,
                       started_at, observed_through_at,
                       MAX(observed_through_at) OVER (
                           PARTITION BY display_id
                           ORDER BY started_at ASC, observed_through_at ASC, sequence ASC
                           ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                       ) AS prior_max_end
                FROM frame_spans
            ), marked AS (
                SELECT *,
                       CASE WHEN prior_max_end IS NULL OR started_at > prior_max_end
                            THEN 1 ELSE 0 END AS starts_island
                FROM ordered
            ), grouped AS (
                SELECT *,
                       SUM(starts_island) OVER (
                           PARTITION BY display_id
                           ORDER BY started_at ASC, observed_through_at ASC, sequence ASC
                           ROWS UNBOUNDED PRECEDING
                       ) AS island_id
                FROM marked
            ), merged AS (
                SELECT display_id, island_id,
                       MIN(started_at) AS island_start,
                       MAX(observed_through_at) AS island_end
                FROM grouped
                GROUP BY display_id, island_id
            )
            SELECT merged.display_id,
                   (
                       SELECT names.display_name
                       FROM frame_spans AS names
                       WHERE names.display_id IS merged.display_id
                         AND names.display_name IS NOT NULL
                       ORDER BY names.observed_through_at DESC, names.sequence DESC
                       LIMIT 1
                   ),
                   MIN(island_start), MAX(island_end),
                   COALESCE(SUM(island_end - island_start), 0), COUNT(*)
            FROM merged
            GROUP BY merged.display_id;
            """
        ) { statement -> [FrameDisplayCoverageStatistics] in
            var values: [FrameDisplayCoverageStatistics] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                let displayID: UUID?
                if sqlite3_column_type(statement, 0) == SQLITE_NULL {
                    displayID = nil
                } else {
                    guard let text = sqlite3_column_text(statement, 0),
                          let decoded = UUID(uuidString: String(cString: text)) else {
                        throw FrameDatabaseError.corrupt("Invalid display ID in coverage aggregate")
                    }
                    displayID = decoded
                }
                let displayName = sqlite3_column_text(statement, 1).map {
                    String(cString: $0)
                }
                let oldestValue = sqlite3_column_double(statement, 2)
                let newestValue = sqlite3_column_double(statement, 3)
                let coveredSeconds = sqlite3_column_double(statement, 4)
                let islandCount = sqlite3_column_int64(statement, 5)
                guard oldestValue.isFinite,
                      newestValue.isFinite,
                      coveredSeconds.isFinite,
                      newestValue >= oldestValue,
                      coveredSeconds >= 0,
                      islandCount >= 1 else {
                    throw FrameDatabaseError.corrupt("Invalid durable coverage aggregate")
                }
                let durable = FrameCoverageIntervalStatistics(
                    oldest: Date(timeIntervalSince1970: oldestValue),
                    newest: Date(timeIntervalSince1970: newestValue),
                    coveredSeconds: coveredSeconds,
                    hasGaps: islandCount > 1
                )
                values.append(FrameDisplayCoverageStatistics(
                    displayID: displayID,
                    displayName: displayName,
                    durable: durable,
                    volatile: .empty,
                    combined: durable
                ))
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else {
                throw sqliteError(message: "Failed to finish reading durable coverage aggregates")
            }
            return values.sorted { lhs, rhs in
                if lhs.displayID == nil { return false }
                if rhs.displayID == nil { return true }
                if lhs.displayLabel != rhs.displayLabel { return lhs.displayLabel < rhs.displayLabel }
                return lhs.id < rhs.id
            }
        }

        let exactCoverage: [FrameDisplayCoverageStatistics]
        if logicalOverlay.isEmpty {
            exactCoverage = displayCoverage
        } else {
            let combined = try combinedDisplayCoverage(logicalOverlay: logicalOverlay)
            let durableByID = Dictionary(uniqueKeysWithValues: displayCoverage.map {
                ($0.id, $0)
            })
            let combinedByID = Dictionary(uniqueKeysWithValues: combined.map {
                ($0.id, $0)
            })
            exactCoverage = Set(durableByID.keys).union(combinedByID.keys).map { id in
                let durable = durableByID[id]
                let combinedValue = combinedByID[id]
                return FrameDisplayCoverageStatistics(
                    displayID: durable?.displayID ?? combinedValue?.displayID,
                    displayName: combinedValue?.displayName ?? durable?.displayName,
                    durable: durable?.durable ?? .empty,
                    volatile: .empty,
                    combined: combinedValue?.combined ?? durable?.durable ?? .empty
                )
            }.sorted { lhs, rhs in
                if lhs.displayID == nil { return false }
                if rhs.displayID == nil { return true }
                if lhs.displayLabel != rhs.displayLabel { return lhs.displayLabel < rhs.displayLabel }
                return lhs.id < rhs.id
            }
        }

        return FrameStorageStatistics(
            durableJPEGPayloadBytes: totals.0,
            frameCount: totals.1,
            timelineSpanCount: totals.2,
            observationCount: totals.3,
            projectionSamples: samples,
            displayCoverage: exactCoverage
        )
    }

    /// Unions the bounded in-memory hybrid overlay with durable spans inside
    /// SQLite. The result remains one aggregate row per display and never
    /// materialises the durable timeline in Swift.
    private func combinedDisplayCoverage(
        logicalOverlay: [TimelineEntry]
    ) throws -> [FrameDisplayCoverageStatistics] {
        try execute(
            """
            CREATE TEMP TABLE IF NOT EXISTS coverage_overlay (
                display_id TEXT,
                display_name TEXT,
                started_at REAL NOT NULL,
                observed_through_at REAL NOT NULL
            );
            """
        )
        try execute("DELETE FROM coverage_overlay;")
        defer { try? execute("DELETE FROM coverage_overlay;") }

        try withPreparedStatement(
            """
            INSERT INTO coverage_overlay (
                display_id, display_name, started_at, observed_through_at
            ) VALUES (?, ?, ?, ?);
            """
        ) { statement in
            for entry in logicalOverlay {
                let bounds = timelineSpanBounds(for: entry)
                guard bindOptionalText(entry.span.displayID?.uuidString, to: statement, index: 1),
                      bindOptionalText(
                          entry.span.displayName ?? entry.frame.displayName,
                          to: statement,
                          index: 2
                      ),
                      sqlite3_bind_double(
                          statement,
                          3,
                          bounds.start.timeIntervalSince1970
                      ) == SQLITE_OK,
                      sqlite3_bind_double(
                          statement,
                          4,
                          bounds.end.timeIntervalSince1970
                      ) == SQLITE_OK,
                      sqlite3_step(statement) == SQLITE_DONE else {
                    throw sqliteError(message: "Failed to insert bounded coverage overlay")
                }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
        }

        return try withPreparedStatement(
            """
            WITH intervals AS (
                SELECT display_id, display_name, sequence AS source_order,
                       started_at, observed_through_at
                FROM frame_spans
                UNION ALL
                SELECT display_id, display_name, rowid AS source_order,
                       started_at, observed_through_at
                FROM coverage_overlay
            ), ordered AS (
                SELECT display_id, display_name, source_order,
                       started_at, observed_through_at,
                       MAX(observed_through_at) OVER (
                           PARTITION BY display_id
                           ORDER BY started_at ASC, observed_through_at ASC, source_order ASC
                           ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                       ) AS prior_max_end
                FROM intervals
            ), marked AS (
                SELECT *,
                       CASE WHEN prior_max_end IS NULL OR started_at > prior_max_end
                            THEN 1 ELSE 0 END AS starts_island
                FROM ordered
            ), grouped AS (
                SELECT *,
                       SUM(starts_island) OVER (
                           PARTITION BY display_id
                           ORDER BY started_at ASC, observed_through_at ASC, source_order ASC
                           ROWS UNBOUNDED PRECEDING
                       ) AS island_id
                FROM marked
            ), merged AS (
                SELECT display_id, island_id,
                       MIN(started_at) AS island_start,
                       MAX(observed_through_at) AS island_end
                FROM grouped
                GROUP BY display_id, island_id
            )
            SELECT merged.display_id,
                   (
                       SELECT names.display_name
                       FROM intervals AS names
                       WHERE names.display_id IS merged.display_id
                         AND names.display_name IS NOT NULL
                       ORDER BY names.observed_through_at DESC, names.source_order DESC
                       LIMIT 1
                   ),
                   MIN(island_start), MAX(island_end),
                   COALESCE(SUM(island_end - island_start), 0), COUNT(*)
            FROM merged
            GROUP BY merged.display_id;
            """
        ) { statement -> [FrameDisplayCoverageStatistics] in
            var values: [FrameDisplayCoverageStatistics] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                let displayID: UUID?
                if sqlite3_column_type(statement, 0) == SQLITE_NULL {
                    displayID = nil
                } else {
                    guard let text = sqlite3_column_text(statement, 0),
                          let decoded = UUID(uuidString: String(cString: text)) else {
                        throw FrameDatabaseError.corrupt("Invalid display ID in combined coverage")
                    }
                    displayID = decoded
                }
                let displayName = sqlite3_column_text(statement, 1).map {
                    String(cString: $0)
                }
                let oldestValue = sqlite3_column_double(statement, 2)
                let newestValue = sqlite3_column_double(statement, 3)
                let coveredSeconds = sqlite3_column_double(statement, 4)
                let islandCount = sqlite3_column_int64(statement, 5)
                guard oldestValue.isFinite,
                      newestValue.isFinite,
                      coveredSeconds.isFinite,
                      newestValue >= oldestValue,
                      coveredSeconds >= 0,
                      islandCount >= 1 else {
                    throw FrameDatabaseError.corrupt("Invalid combined coverage aggregate")
                }
                let combined = FrameCoverageIntervalStatistics(
                    oldest: Date(timeIntervalSince1970: oldestValue),
                    newest: Date(timeIntervalSince1970: newestValue),
                    coveredSeconds: coveredSeconds,
                    hasGaps: islandCount > 1
                )
                values.append(FrameDisplayCoverageStatistics(
                    displayID: displayID,
                    displayName: displayName,
                    durable: .empty,
                    volatile: .empty,
                    combined: combined
                ))
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else {
                throw sqliteError(message: "Failed to finish combined coverage aggregate")
            }
            return values
        }
    }

    static func logicalByteCount(for metadata: FrameMetadata) -> Int {
        MemoryLayout<Double>.size
            + MemoryLayout<UInt64>.size
            + MemoryLayout<Int64>.size
            + metadata.id.uuidString.utf8.count
            + metadata.filename.utf8.count
            + metadata.thumbnailFilename.utf8.count
            + (metadata.displayID?.uuidString.utf8.count ?? 0)
            + (metadata.displayName?.utf8.count ?? 0)
    }

    static func logicalByteCount(for span: TimelineSpan) -> Int {
        MemoryLayout<Double>.size * 2
            + MemoryLayout<Int64>.size
            + span.id.uuidString.utf8.count
            + span.frameID.uuidString.utf8.count
            + span.sessionID.uuidString.utf8.count
            + (span.displayID?.uuidString.utf8.count ?? 0)
            + (span.displayName?.utf8.count ?? 0)
    }

    static func logicalByteCount(for entry: TimelineEntry) -> Int {
        logicalByteCount(for: FrameMetadata(
            id: entry.frame.id,
            timestamp: entry.frame.timestamp,
            hash: entry.frame.hash,
            filename: "\(entry.frame.id.uuidString).jpg",
            thumbnailFilename: "\(entry.frame.id.uuidString)_thumb.jpg",
            fileSize: 0,
            displayID: entry.frame.displayID,
            displayName: entry.frame.displayName
        )) + logicalByteCount(for: entry.span)
    }

    private func validateOrCreateSchema() throws {
        let version = try userVersion()
        switch version {
        case 0:
            let hasFramesTable = try tableExists("frames")
            let hasMetadataTable = try tableExists("store_meta")
            guard !hasFramesTable && !hasMetadataTable else {
                throw FrameDatabaseError.corrupt("Partially initialised frame database")
            }
            try withTransaction {
                try execute(
                    """
                    CREATE TABLE store_meta (
                        key TEXT PRIMARY KEY NOT NULL,
                        value TEXT NOT NULL
                    );
                    """
                )
                try execute(
                    """
                    CREATE TABLE frames (
                        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                        id TEXT NOT NULL UNIQUE,
                        captured_at REAL NOT NULL,
                        perceptual_hash BLOB NOT NULL CHECK(length(perceptual_hash) = 8),
                        filename TEXT NOT NULL UNIQUE,
                        thumbnail_filename TEXT NOT NULL UNIQUE,
                        file_size INTEGER NOT NULL CHECK(file_size >= 0),
                        display_id TEXT,
                        display_name TEXT
                    );
                    """
                )
                try execute(
                    "CREATE INDEX idx_frames_captured_at " +
                        "ON frames(captured_at ASC, sequence ASC);"
                )
                try execute(
                    "CREATE INDEX idx_frames_display_captured_at " +
                        "ON frames(display_id, captured_at DESC, sequence DESC);"
                )
                try createSessionAndSpanSchema()
                try execute("PRAGMA user_version=\(Self.schemaVersion);")
            }
            try validateCurrentSchema()
        case 1:
            try validateVersion1Schema()
            try withTransaction {
                try createSessionAndSpanSchema()
                try migrateVersion1RowsToSpans()
                try execute("PRAGMA user_version=\(Self.schemaVersion);")
            }
            try validateCurrentSchema()
        case Self.schemaVersion:
            guard try tableExists("frames"),
                  try tableExists("store_meta"),
                  try tableExists("capture_sessions"),
                  try tableExists("frame_spans") else {
                throw FrameDatabaseError.corrupt("Frame database schema is incomplete")
            }
            try validateCurrentSchema()
        default:
            throw FrameDatabaseError.unsupportedSchema(version)
        }
    }

    private func createSessionAndSpanSchema() throws {
        try execute(
            """
            CREATE TABLE capture_sessions (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                id TEXT NOT NULL UNIQUE,
                started_at REAL NOT NULL,
                ended_at REAL,
                end_reason TEXT,
                CHECK(ended_at IS NULL OR ended_at >= started_at),
                CHECK((ended_at IS NULL AND end_reason IS NULL) OR
                      (ended_at IS NOT NULL AND end_reason IS NOT NULL))
            );
            """
        )
        try execute(
            """
            CREATE TABLE frame_spans (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                id TEXT NOT NULL UNIQUE,
                frame_id TEXT NOT NULL REFERENCES frames(id) ON DELETE RESTRICT,
                session_id TEXT NOT NULL REFERENCES capture_sessions(id) ON DELETE CASCADE,
                started_at REAL NOT NULL,
                observed_through_at REAL NOT NULL,
                observation_count INTEGER NOT NULL CHECK(observation_count >= 1),
                display_id TEXT,
                display_name TEXT,
                CHECK(observed_through_at >= started_at)
            );
            """
        )
        try execute(
            "CREATE UNIQUE INDEX idx_capture_sessions_single_open " +
                "ON capture_sessions((1)) WHERE ended_at IS NULL;"
        )
        try execute(
            "CREATE INDEX idx_frame_spans_started_at " +
                "ON frame_spans(started_at ASC, sequence ASC);"
        )
        try execute(
            "CREATE INDEX idx_frame_spans_display_started_at " +
                "ON frame_spans(display_id, started_at DESC, sequence DESC);"
        )
        try execute(
            "CREATE INDEX idx_frame_spans_session_display " +
                "ON frame_spans(session_id, display_id, sequence DESC);"
        )
        try execute("CREATE INDEX idx_frame_spans_frame_id ON frame_spans(frame_id);")
    }

    private func migrateVersion1RowsToSpans() throws {
        guard try frameCount() > 0 else { return }
        let sessionID = UUID()
        let bounds = try withPreparedStatement(
            "SELECT MIN(captured_at), MAX(captured_at) FROM frames;"
        ) { statement -> (Date, Date) in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw sqliteError(message: "Failed to read version 1 timeline bounds")
            }
            let lower = sqlite3_column_double(statement, 0)
            let upper = sqlite3_column_double(statement, 1)
            guard lower.isFinite, upper.isFinite else {
                throw FrameDatabaseError.corrupt("Invalid version 1 timeline bounds")
            }
            try requireDone(statement, message: "Failed to finish version 1 timeline bounds")
            return (Date(timeIntervalSince1970: lower), Date(timeIntervalSince1970: upper))
        }
        try insertSession(
            CaptureSession(
                id: sessionID,
                startedAt: bounds.0,
                endedAt: bounds.1,
                endReason: .legacyMigration
            )
        )
        try withPreparedStatement(
            """
            INSERT INTO frame_spans (
                sequence, id, frame_id, session_id, started_at,
                observed_through_at, observation_count, display_id, display_name
            )
            SELECT sequence, id, id, ?, captured_at, captured_at, 1, display_id, display_name
            FROM frames
            ORDER BY sequence ASC;
            """
        ) { statement in
            guard bindText(sessionID.uuidString, to: statement, index: 1),
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteError(message: "Failed to migrate version 1 frame spans")
            }
        }
    }

    private func userVersion() throws -> Int {
        try pragmaInt("PRAGMA user_version;")
    }

    private func pragmaInt(_ sql: String) throws -> Int {
        try withPreparedStatement(sql) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw sqliteError(message: "Failed to read SQLite pragma")
            }
            let value = Int(sqlite3_column_int(statement, 0))
            try requireDone(statement, message: "Failed to finish reading SQLite pragma")
            return value
        }
    }

    private func tableExists(_ name: String) throws -> Bool {
        try withPreparedStatement(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;"
        ) { statement in
            guard bindText(name, to: statement, index: 1) else {
                throw sqliteError(message: "Failed to bind table name")
            }
            switch sqlite3_step(statement) {
            case SQLITE_DONE:
                return false
            case SQLITE_ROW:
                try requireDone(statement, message: "Failed to finish checking table existence")
                return true
            default:
                throw sqliteError(message: "Failed to check table existence")
            }
        }
    }

    private func validateCurrentSchema() throws {
        try validateVersion1Schema()
        let expectedSessionColumns: [ColumnDefinition] = [
            ColumnDefinition(name: "sequence", type: "INTEGER", notNull: 0, primaryKeyPosition: 1),
            ColumnDefinition(name: "id", type: "TEXT", notNull: 1, primaryKeyPosition: 0),
            ColumnDefinition(name: "started_at", type: "REAL", notNull: 1, primaryKeyPosition: 0),
            ColumnDefinition(name: "ended_at", type: "REAL", notNull: 0, primaryKeyPosition: 0),
            ColumnDefinition(name: "end_reason", type: "TEXT", notNull: 0, primaryKeyPosition: 0)
        ]
        let expectedSpanColumns: [ColumnDefinition] = [
            ColumnDefinition(name: "sequence", type: "INTEGER", notNull: 0, primaryKeyPosition: 1),
            ColumnDefinition(name: "id", type: "TEXT", notNull: 1, primaryKeyPosition: 0),
            ColumnDefinition(name: "frame_id", type: "TEXT", notNull: 1, primaryKeyPosition: 0),
            ColumnDefinition(name: "session_id", type: "TEXT", notNull: 1, primaryKeyPosition: 0),
            ColumnDefinition(name: "started_at", type: "REAL", notNull: 1, primaryKeyPosition: 0),
            ColumnDefinition(name: "observed_through_at", type: "REAL", notNull: 1, primaryKeyPosition: 0),
            ColumnDefinition(name: "observation_count", type: "INTEGER", notNull: 1, primaryKeyPosition: 0),
            ColumnDefinition(name: "display_id", type: "TEXT", notNull: 0, primaryKeyPosition: 0),
            ColumnDefinition(name: "display_name", type: "TEXT", notNull: 0, primaryKeyPosition: 0)
        ]
        guard try tableColumns("capture_sessions") == expectedSessionColumns,
              try tableColumns("frame_spans") == expectedSpanColumns,
              try indexColumns("idx_frame_spans_started_at") == [
                  IndexColumn(name: "started_at", descending: 0),
                  IndexColumn(name: "sequence", descending: 0)
              ],
              try indexColumns("idx_frame_spans_display_started_at") == [
                  IndexColumn(name: "display_id", descending: 0),
                  IndexColumn(name: "started_at", descending: 1),
                  IndexColumn(name: "sequence", descending: 1)
              ],
              try indexColumns("idx_frame_spans_session_display") == [
                  IndexColumn(name: "session_id", descending: 0),
                  IndexColumn(name: "display_id", descending: 0),
                  IndexColumn(name: "sequence", descending: 1)
              ],
              try indexColumns("idx_frame_spans_frame_id") == [
                  IndexColumn(name: "frame_id", descending: 0)
              ],
              try hasUniqueSingleColumnIndex(table: "capture_sessions", column: "id"),
              try hasUniqueSingleColumnIndex(table: "frame_spans", column: "id"),
              let sessionsSQL = try schemaSQL(for: "capture_sessions")?.lowercased(),
              sessionsSQL.contains("ended_at >= started_at"),
              let spansSQL = try schemaSQL(for: "frame_spans")?.lowercased(),
              spansSQL.contains("references frames(id) on delete restrict"),
              spansSQL.contains("references capture_sessions(id) on delete cascade"),
              spansSQL.contains("observation_count >= 1"),
              spansSQL.contains("observed_through_at >= started_at"),
              let openIndexSQL = try indexSQL(for: "idx_capture_sessions_single_open")?.lowercased(),
              openIndexSQL.contains("unique index"),
              openIndexSQL.contains("where ended_at is null") else {
            throw FrameDatabaseError.corrupt("Frame database schema does not match version 2")
        }
        try foreignKeyCheck()
        _ = try allTimelineEntries()
        _ = try allSessions()
    }

    private func validateVersion1Schema() throws {
        let expectedFrameColumns: [ColumnDefinition] = [
            ColumnDefinition(name: "sequence", type: "INTEGER", notNull: 0, primaryKeyPosition: 1),
            ColumnDefinition(name: "id", type: "TEXT", notNull: 1, primaryKeyPosition: 0),
            ColumnDefinition(name: "captured_at", type: "REAL", notNull: 1, primaryKeyPosition: 0),
            ColumnDefinition(name: "perceptual_hash", type: "BLOB", notNull: 1, primaryKeyPosition: 0),
            ColumnDefinition(name: "filename", type: "TEXT", notNull: 1, primaryKeyPosition: 0),
            ColumnDefinition(name: "thumbnail_filename", type: "TEXT", notNull: 1, primaryKeyPosition: 0),
            ColumnDefinition(name: "file_size", type: "INTEGER", notNull: 1, primaryKeyPosition: 0),
            ColumnDefinition(name: "display_id", type: "TEXT", notNull: 0, primaryKeyPosition: 0),
            ColumnDefinition(name: "display_name", type: "TEXT", notNull: 0, primaryKeyPosition: 0)
        ]
        let expectedMetadataColumns: [ColumnDefinition] = [
            ColumnDefinition(name: "key", type: "TEXT", notNull: 1, primaryKeyPosition: 1),
            ColumnDefinition(name: "value", type: "TEXT", notNull: 1, primaryKeyPosition: 0)
        ]
        guard try tableColumns("frames") == expectedFrameColumns,
              try tableColumns("store_meta") == expectedMetadataColumns,
              try indexColumns("idx_frames_captured_at") == [
                  IndexColumn(name: "captured_at", descending: 0),
                  IndexColumn(name: "sequence", descending: 0)
              ],
              try indexColumns("idx_frames_display_captured_at") == [
                  IndexColumn(name: "display_id", descending: 0),
                  IndexColumn(name: "captured_at", descending: 1),
                  IndexColumn(name: "sequence", descending: 1)
              ],
              try hasUniqueSingleColumnIndex(table: "frames", column: "id"),
              try hasUniqueSingleColumnIndex(table: "frames", column: "filename"),
              try hasUniqueSingleColumnIndex(table: "frames", column: "thumbnail_filename"),
              let schemaSQL = try schemaSQL(for: "frames")?.lowercased(),
              schemaSQL.contains("autoincrement"),
              schemaSQL.contains("check(length(perceptual_hash) = 8)"),
              schemaSQL.contains("check(file_size >= 0)") else {
            throw FrameDatabaseError.corrupt("Frame database frame schema does not match version 1")
        }
    }

    private func tableColumns(_ table: String) throws -> [ColumnDefinition] {
        guard ["frames", "store_meta", "capture_sessions", "frame_spans"].contains(table) else {
            throw FrameDatabaseError.corrupt("Unexpected frame database table")
        }
        return try withPreparedStatement("PRAGMA table_info(\(table));") { statement in
            var columns: [ColumnDefinition] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                guard let rawName = sqlite3_column_text(statement, 1),
                      let rawType = sqlite3_column_text(statement, 2) else {
                    throw FrameDatabaseError.corrupt("Invalid frame database column")
                }
                columns.append(
                    ColumnDefinition(
                        name: String(cString: rawName),
                        type: String(cString: rawType).uppercased(),
                        notNull: sqlite3_column_int(statement, 3),
                        primaryKeyPosition: sqlite3_column_int(statement, 5)
                    )
                )
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else {
                throw sqliteError(message: "Failed to finish reading frame database columns")
            }
            return columns
        }
    }

    private func schemaSQL(for table: String) throws -> String? {
        try withPreparedStatement(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;"
        ) { statement in
            guard bindText(table, to: statement, index: 1) else {
                throw sqliteError(message: "Failed to bind schema table name")
            }
            switch sqlite3_step(statement) {
            case SQLITE_DONE:
                return nil
            case SQLITE_ROW:
                guard let rawSQL = sqlite3_column_text(statement, 0) else {
                    throw FrameDatabaseError.corrupt("Invalid frame database schema SQL")
                }
                let sql = String(cString: rawSQL)
                try requireDone(statement, message: "Failed to finish reading frame database schema")
                return sql
            default:
                throw sqliteError(message: "Failed to read frame database schema")
            }
        }
    }

    private func indexSQL(for name: String) throws -> String? {
        try withPreparedStatement(
            "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ? LIMIT 1;"
        ) { statement in
            guard bindText(name, to: statement, index: 1) else {
                throw sqliteError(message: "Failed to bind schema index name")
            }
            switch sqlite3_step(statement) {
            case SQLITE_DONE:
                return nil
            case SQLITE_ROW:
                guard let rawSQL = sqlite3_column_text(statement, 0) else {
                    throw FrameDatabaseError.corrupt("Invalid frame database index SQL")
                }
                let sql = String(cString: rawSQL)
                try requireDone(statement, message: "Failed to finish reading frame index schema")
                return sql
            default:
                throw sqliteError(message: "Failed to read frame index schema")
            }
        }
    }

    private func hasUniqueSingleColumnIndex(table: String, column: String) throws -> Bool {
        guard ["frames", "capture_sessions", "frame_spans"].contains(table) else { return false }
        let escapedTable = table.replacingOccurrences(of: "\"", with: "\"\"")
        return try withPreparedStatement("PRAGMA index_list(\"\(escapedTable)\");") { statement in
            var found = false
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                guard sqlite3_column_int(statement, 2) == 1,
                      let rawName = sqlite3_column_text(statement, 1) else {
                    result = sqlite3_step(statement)
                    continue
                }
                let name = String(cString: rawName)
                if try indexColumns(name).map(\.name) == [column] {
                    found = true
                }
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else {
                throw sqliteError(message: "Failed to finish reading frame database indexes")
            }
            return found
        }
    }

    private func indexColumns(_ name: String) throws -> [IndexColumn] {
        let escapedName = name.replacingOccurrences(of: "\"", with: "\"\"")
        return try withPreparedStatement("PRAGMA index_xinfo(\"\(escapedName)\");") { statement in
            var values: [IndexColumn] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                // Auxiliary rowid columns have key=0 and are not part of the
                // declared index definition.
                guard sqlite3_column_int(statement, 5) == 1,
                      let rawColumn = sqlite3_column_text(statement, 2) else {
                    result = sqlite3_step(statement)
                    continue
                }
                values.append(
                    IndexColumn(
                        name: String(cString: rawColumn),
                        descending: sqlite3_column_int(statement, 3)
                    )
                )
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else {
                throw sqliteError(message: "Failed to finish reading frame database index columns")
            }
            return values
        }
    }

    private func insertRow(_ metadata: FrameMetadata, preservingSequence sequence: Int64?) throws {
        let sql: String
        if sequence == nil {
            sql =
                """
                INSERT INTO frames (
                    id, captured_at, perceptual_hash, filename,
                    thumbnail_filename, file_size, display_id, display_name
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """
        } else {
            sql =
                """
                INSERT INTO frames (
                    sequence, id, captured_at, perceptual_hash, filename,
                    thumbnail_filename, file_size, display_id, display_name
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
        }

        try withPreparedStatement(sql) { statement in
            var index: Int32 = 1
            if let sequence {
                guard sqlite3_bind_int64(statement, index, sequence) == SQLITE_OK else {
                    throw sqliteError(message: "Failed to bind legacy frame sequence")
                }
                index += 1
            }

            guard bindText(metadata.id.uuidString, to: statement, index: index) else {
                throw sqliteError(message: "Failed to bind frame ID")
            }
            index += 1
            guard sqlite3_bind_double(statement, index, metadata.timestamp.timeIntervalSince1970) == SQLITE_OK else {
                throw sqliteError(message: "Failed to bind frame timestamp")
            }
            index += 1
            guard bindHash(metadata.hash, to: statement, index: index) else {
                throw sqliteError(message: "Failed to bind frame hash")
            }
            index += 1
            guard bindText(metadata.filename, to: statement, index: index) else {
                throw sqliteError(message: "Failed to bind frame filename")
            }
            index += 1
            guard bindText(metadata.thumbnailFilename, to: statement, index: index) else {
                throw sqliteError(message: "Failed to bind frame thumbnail filename")
            }
            index += 1
            guard sqlite3_bind_int64(statement, index, metadata.fileSize) == SQLITE_OK else {
                throw sqliteError(message: "Failed to bind frame file size")
            }
            index += 1
            guard bindOptionalText(metadata.displayID?.uuidString, to: statement, index: index) else {
                throw sqliteError(message: "Failed to bind frame display ID")
            }
            index += 1
            guard bindOptionalText(metadata.displayName, to: statement, index: index),
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteError(message: "Failed to insert frame metadata")
            }
        }
    }

    private func insertSession(_ session: CaptureSession) throws {
        try withPreparedStatement(
            """
            INSERT INTO capture_sessions (id, started_at, ended_at, end_reason)
            VALUES (?, ?, ?, ?);
            """
        ) { statement in
            guard bindText(session.id.uuidString, to: statement, index: 1),
                  sqlite3_bind_double(statement, 2, session.startedAt.timeIntervalSince1970) == SQLITE_OK else {
                throw sqliteError(message: "Failed to bind capture session")
            }
            if let endedAt = session.endedAt {
                guard sqlite3_bind_double(statement, 3, endedAt.timeIntervalSince1970) == SQLITE_OK else {
                    throw sqliteError(message: "Failed to bind capture session end")
                }
            } else {
                guard sqlite3_bind_null(statement, 3) == SQLITE_OK else {
                    throw sqliteError(message: "Failed to bind open capture session end")
                }
            }
            guard bindOptionalText(session.endReason?.rawValue, to: statement, index: 4),
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteError(message: "Failed to insert capture session")
            }
        }
    }

    private func insertSpan(_ span: TimelineSpan, preservingSequence sequence: Int64?) throws {
        let sql: String
        if sequence == nil {
            sql =
                """
                INSERT INTO frame_spans (
                    id, frame_id, session_id, started_at, observed_through_at,
                    observation_count, display_id, display_name
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """
        } else {
            sql =
                """
                INSERT INTO frame_spans (
                    sequence, id, frame_id, session_id, started_at, observed_through_at,
                    observation_count, display_id, display_name
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
        }
        try withPreparedStatement(sql) { statement in
            var index: Int32 = 1
            if let sequence {
                guard sqlite3_bind_int64(statement, index, sequence) == SQLITE_OK else {
                    throw sqliteError(message: "Failed to bind span sequence")
                }
                index += 1
            }
            guard bindText(span.id.uuidString, to: statement, index: index) else {
                throw sqliteError(message: "Failed to bind span ID")
            }
            index += 1
            guard bindText(span.frameID.uuidString, to: statement, index: index) else {
                throw sqliteError(message: "Failed to bind span frame ID")
            }
            index += 1
            guard bindText(span.sessionID.uuidString, to: statement, index: index) else {
                throw sqliteError(message: "Failed to bind span session ID")
            }
            index += 1
            guard sqlite3_bind_double(statement, index, span.startedAt.timeIntervalSince1970) == SQLITE_OK else {
                throw sqliteError(message: "Failed to bind span start")
            }
            index += 1
            guard sqlite3_bind_double(statement, index, span.observedThroughAt.timeIntervalSince1970) == SQLITE_OK else {
                throw sqliteError(message: "Failed to bind span observation end")
            }
            index += 1
            guard sqlite3_bind_int64(statement, index, Int64(span.observationCount)) == SQLITE_OK else {
                throw sqliteError(message: "Failed to bind span observation count")
            }
            index += 1
            guard bindOptionalText(span.displayID?.uuidString, to: statement, index: index) else {
                throw sqliteError(message: "Failed to bind span display ID")
            }
            index += 1
            guard bindOptionalText(span.displayName, to: statement, index: index),
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteError(message: "Failed to insert timeline span")
            }
        }
    }

    private func span(for id: UUID) throws -> TimelineSpan? {
        try withPreparedStatement(
            """
            SELECT id, frame_id, session_id, started_at, observed_through_at,
                   observation_count, display_id, display_name
            FROM frame_spans WHERE id = ? LIMIT 1;
            """
        ) { statement in
            guard bindText(id.uuidString, to: statement, index: 1) else {
                throw sqliteError(message: "Failed to bind span ID")
            }
            switch sqlite3_step(statement) {
            case SQLITE_DONE:
                return nil
            case SQLITE_ROW:
                let value = try decodeSpan(from: statement)
                try requireDone(statement, message: "Failed to finish reading timeline span")
                return value
            default:
                throw sqliteError(message: "Failed to read timeline span")
            }
        }
    }

    private func promotionPlan(
        for entry: TimelineEntry,
        metadata requestedMetadata: FrameMetadata
    ) throws -> DurablePlan {
        try validatePromotionInvariants(entry, metadata: requestedMetadata)
        try validateActiveSession(for: entry.span)

        let existingMetadata = try metadata(for: entry.frame.id)
        let existingSpan = try span(for: entry.span.id)
        switch (existingMetadata, existingSpan) {
        case (nil, nil):
            return .insert

        case (.some(let metadata), .some(let span)):
            guard metadataMatches(metadata, requestedMetadata),
                  immutableSpanFieldsMatch(span, entry.span) else {
                throw FrameDatabaseError.promotionConflict(
                    "Promotion retry conflicts with durable frame or span metadata"
                )
            }
            let committed = TimelineEntry(span: span, frame: storedFrame(from: metadata))
            return try monotonicPlan(current: committed, requested: entry.span)

        case (.some, nil), (nil, .some):
            throw FrameDatabaseError.promotionConflict(
                "Promotion frame/span identity partially collides with durable state"
            )
        }
    }

    private func checkpointPlan(for requested: TimelineSpan) throws -> DurablePlan {
        try validateSpanInvariants(requested)
        try validateActiveSession(for: requested)
        guard let metadata = try metadata(for: requested.frameID),
              let existing = try span(for: requested.id) else {
            throw FrameDatabaseError.promotionConflict("Checkpoint target is not durable")
        }
        guard immutableSpanFieldsMatch(existing, requested) else {
            throw FrameDatabaseError.promotionConflict(
                "Checkpoint conflicts with immutable durable span metadata"
            )
        }
        let committed = TimelineEntry(span: existing, frame: storedFrame(from: metadata))
        return try monotonicPlan(current: committed, requested: requested)
    }

    private func monotonicPlan(
        current: TimelineEntry,
        requested: TimelineSpan
    ) throws -> DurablePlan {
        let currentEnd = current.span.observedThroughAt.timeIntervalSince1970
        let requestedEnd = requested.observedThroughAt.timeIntervalSince1970
        let advances = requestedEnd >= currentEnd
            && requested.observationCount >= current.span.observationCount
        let isOlder = requestedEnd <= currentEnd
            && requested.observationCount <= current.span.observationCount
        guard advances || isOlder else {
            throw FrameDatabaseError.promotionConflict(
                "Span end and observation count do not advance monotonically"
            )
        }
        if requestedEnd == currentEnd,
           requested.observationCount == current.span.observationCount {
            return .noOp(current)
        }
        return advances ? .checkpoint : .noOp(current)
    }

    private func validatePromotionInvariants(
        _ entry: TimelineEntry,
        metadata: FrameMetadata
    ) throws {
        try validateSpanInvariants(entry.span)
        let frameTimestamp = entry.frame.timestamp.timeIntervalSince1970
        guard entry.span.frameID == entry.frame.id,
              metadata.id == entry.frame.id,
              frameTimestamp.isFinite,
              frameTimestamp == entry.span.startedAt.timeIntervalSince1970,
              entry.frame.displayID == entry.span.displayID,
              metadata.fileSize >= 0,
              metadata.timestamp.timeIntervalSince1970 == frameTimestamp,
              metadata.hash == entry.frame.hash,
              metadata.displayID == entry.frame.displayID,
              metadata.displayName == entry.frame.displayName else {
            throw FrameDatabaseError.invalidPromotion("Invalid volatile timeline entry")
        }
    }

    private func validateSpanInvariants(_ span: TimelineSpan) throws {
        let start = span.startedAt.timeIntervalSince1970
        let end = span.observedThroughAt.timeIntervalSince1970
        guard start.isFinite,
              end.isFinite,
              end >= start,
              span.observationCount >= 1 else {
            throw FrameDatabaseError.invalidPromotion("Invalid promoted span bounds or count")
        }
    }

    private func validateActiveSession(for span: TimelineSpan) throws {
        guard let session = try session(for: span.sessionID) else {
            throw FrameDatabaseError.captureSessionNotFound(span.sessionID)
        }
        let activeID = try activeSession()?.id
        guard session.endedAt == nil, activeID == span.sessionID else {
            throw FrameDatabaseError.captureSessionMismatch(
                expected: span.sessionID,
                active: activeID
            )
        }
        guard span.startedAt.timeIntervalSince1970
            >= session.startedAt.timeIntervalSince1970 else {
            throw FrameDatabaseError.invalidPromotion(
                "Promoted span predates its capture session"
            )
        }
    }

    private func metadataMatches(_ lhs: FrameMetadata, _ rhs: FrameMetadata) -> Bool {
        lhs.id == rhs.id
            && lhs.timestamp.timeIntervalSince1970 == rhs.timestamp.timeIntervalSince1970
            && lhs.hash == rhs.hash
            && lhs.filename == rhs.filename
            && lhs.thumbnailFilename == rhs.thumbnailFilename
            && lhs.fileSize == rhs.fileSize
            && lhs.displayID == rhs.displayID
            && lhs.displayName == rhs.displayName
    }

    private func immutableSpanFieldsMatch(_ lhs: TimelineSpan, _ rhs: TimelineSpan) -> Bool {
        lhs.id == rhs.id
            && lhs.frameID == rhs.frameID
            && lhs.sessionID == rhs.sessionID
            && lhs.startedAt.timeIntervalSince1970 == rhs.startedAt.timeIntervalSince1970
            && lhs.displayID == rhs.displayID
    }

    private func updatePromotedSpanAbsolute(_ span: TimelineSpan) throws {
        try withPreparedStatement(
            """
            UPDATE frame_spans
            SET observed_through_at = ?, observation_count = ?,
                display_name = COALESCE(?, display_name)
            WHERE id = ?;
            """
        ) { statement in
            guard sqlite3_bind_double(
                statement,
                1,
                span.observedThroughAt.timeIntervalSince1970
            ) == SQLITE_OK,
            sqlite3_bind_int64(statement, 2, Int64(span.observationCount)) == SQLITE_OK,
            bindOptionalText(span.displayName, to: statement, index: 3),
            bindText(span.id.uuidString, to: statement, index: 4),
            sqlite3_step(statement) == SQLITE_DONE,
            sqlite3_changes(db) == 1 else {
                throw sqliteError(message: "Failed to checkpoint promoted span")
            }
        }
    }

    private func timelineEntries(
        sql: String,
        bind: ((OpaquePointer) throws -> Void)? = nil
    ) throws -> [TimelineEntry] {
        try withPreparedStatement(sql) { statement in
            try bind?(statement)
            var entries: [TimelineEntry] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                let span = try decodeSpan(from: statement)
                let metadata = try decodeMetadata(from: statement, offset: 8)
                guard metadata.id == span.frameID else {
                    throw FrameDatabaseError.corrupt("Timeline span resolves to the wrong frame")
                }
                entries.append(TimelineEntry(span: span, frame: storedFrame(from: metadata)))
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else {
                throw sqliteError(message: "Failed to finish reading timeline entries")
            }
            return entries
        }
    }

    private func decodeSpan(from statement: OpaquePointer, offset: Int32 = 0) throws -> TimelineSpan {
        guard let rawID = sqlite3_column_text(statement, offset),
              let id = UUID(uuidString: String(cString: rawID)),
              let rawFrameID = sqlite3_column_text(statement, offset + 1),
              let frameID = UUID(uuidString: String(cString: rawFrameID)),
              let rawSessionID = sqlite3_column_text(statement, offset + 2),
              let sessionID = UUID(uuidString: String(cString: rawSessionID)) else {
            throw FrameDatabaseError.corrupt("Invalid timeline span identity")
        }
        let startedAt = sqlite3_column_double(statement, offset + 3)
        let observedThroughAt = sqlite3_column_double(statement, offset + 4)
        let observationCount = sqlite3_column_int64(statement, offset + 5)
        guard startedAt.isFinite,
              observedThroughAt.isFinite,
              observedThroughAt >= startedAt,
              observationCount >= 1,
              observationCount <= Int64(Int.max) else {
            throw FrameDatabaseError.corrupt("Invalid timeline span interval")
        }
        let displayID = try decodeOptionalUUID(from: statement, column: offset + 6)
        let displayName = sqlite3_column_text(statement, offset + 7).map { String(cString: $0) }
        return TimelineSpan(
            id: id,
            frameID: frameID,
            sessionID: sessionID,
            startedAt: Date(timeIntervalSince1970: startedAt),
            observedThroughAt: Date(timeIntervalSince1970: observedThroughAt),
            observationCount: Int(observationCount),
            displayID: displayID,
            displayName: displayName
        )
    }

    private func decodeSession(from statement: OpaquePointer) throws -> CaptureSession {
        guard let rawID = sqlite3_column_text(statement, 0),
              let id = UUID(uuidString: String(cString: rawID)) else {
            throw FrameDatabaseError.corrupt("Invalid capture session ID")
        }
        let startedAt = sqlite3_column_double(statement, 1)
        guard startedAt.isFinite else {
            throw FrameDatabaseError.corrupt("Invalid capture session start")
        }
        let endedAt: Date?
        if sqlite3_column_type(statement, 2) == SQLITE_NULL {
            endedAt = nil
        } else {
            let value = sqlite3_column_double(statement, 2)
            guard value.isFinite, value >= startedAt else {
                throw FrameDatabaseError.corrupt("Invalid capture session end")
            }
            endedAt = Date(timeIntervalSince1970: value)
        }
        let endReason: CaptureSessionEndReason?
        if let rawReason = sqlite3_column_text(statement, 3) {
            guard let decoded = CaptureSessionEndReason(rawValue: String(cString: rawReason)) else {
                throw FrameDatabaseError.corrupt("Invalid capture session end reason")
            }
            endReason = decoded
        } else {
            endReason = nil
        }
        guard (endedAt == nil) == (endReason == nil) else {
            throw FrameDatabaseError.corrupt("Inconsistent capture session end state")
        }
        return CaptureSession(
            id: id,
            startedAt: Date(timeIntervalSince1970: startedAt),
            endedAt: endedAt,
            endReason: endReason
        )
    }

    private func session(for id: UUID) throws -> CaptureSession? {
        try withPreparedStatement(
            "SELECT id, started_at, ended_at, end_reason FROM capture_sessions WHERE id = ? LIMIT 1;"
        ) { statement in
            guard bindText(id.uuidString, to: statement, index: 1) else {
                throw sqliteError(message: "Failed to bind capture session ID")
            }
            switch sqlite3_step(statement) {
            case SQLITE_DONE:
                return nil
            case SQLITE_ROW:
                let session = try decodeSession(from: statement)
                try requireDone(statement, message: "Failed to finish reading capture session")
                return session
            default:
                throw sqliteError(message: "Failed to read capture session")
            }
        }
    }

    func allSessions() throws -> [CaptureSession] {
        try withPreparedStatement(
            "SELECT id, started_at, ended_at, end_reason FROM capture_sessions ORDER BY sequence ASC;"
        ) { statement in
            var sessions: [CaptureSession] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                sessions.append(try decodeSession(from: statement))
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else {
                throw sqliteError(message: "Failed to finish reading capture sessions")
            }
            return sessions
        }
    }

    private func closeInterruptedSession() throws {
        guard let active = try activeSession() else { return }
        try endCaptureSession(id: active.id, reason: .interrupted)
    }

    private func foreignKeyCheck() throws {
        try withPreparedStatement("PRAGMA foreign_key_check;") { statement in
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw FrameDatabaseError.corrupt("Frame database foreign-key check failed")
            }
        }
    }

    private func frameIDs(forSpanIDs ids: Set<UUID>) throws -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        let values = Array(ids)
        var resultIDs = Set<UUID>()
        for start in stride(from: 0, to: values.count, by: 400) {
            let end = min(start + 400, values.count)
            let chunk = Array(values[start..<end])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try withPreparedStatement(
                "SELECT DISTINCT frame_id FROM frame_spans WHERE id IN (\(placeholders));"
            ) { statement in
                for (offset, id) in chunk.enumerated() {
                    guard bindText(id.uuidString, to: statement, index: Int32(offset + 1)) else {
                        throw sqliteError(message: "Failed to bind span ID for lookup")
                    }
                }
                var result = sqlite3_step(statement)
                while result == SQLITE_ROW {
                    guard let rawID = sqlite3_column_text(statement, 0),
                          let id = UUID(uuidString: String(cString: rawID)) else {
                        throw FrameDatabaseError.corrupt("Invalid span frame reference")
                    }
                    resultIDs.insert(id)
                    result = sqlite3_step(statement)
                }
                guard result == SQLITE_DONE else {
                    throw sqliteError(message: "Failed to finish span frame lookup")
                }
            }
        }
        return resultIDs
    }

    private func spanReferenceCount(frameID: UUID) throws -> Int {
        try withPreparedStatement("SELECT COUNT(*) FROM frame_spans WHERE frame_id = ?;") { statement in
            guard bindText(frameID.uuidString, to: statement, index: 1),
                  sqlite3_step(statement) == SQLITE_ROW else {
                throw sqliteError(message: "Failed to count span references")
            }
            let count = Int(sqlite3_column_int64(statement, 0))
            try requireDone(statement, message: "Failed to finish span reference count")
            return count
        }
    }

    private func deleteRows(table: String, column: String, ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        let allowed = [
            ("frame_spans", "id"),
            ("frame_spans", "frame_id"),
            ("frames", "id")
        ]
        guard allowed.contains(where: { $0.0 == table && $0.1 == column }) else {
            throw FrameDatabaseError.corrupt("Unexpected deletion target")
        }
        let values = Array(ids)
        for start in stride(from: 0, to: values.count, by: 400) {
            let end = min(start + 400, values.count)
            let chunk = Array(values[start..<end])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try withPreparedStatement("DELETE FROM \(table) WHERE \(column) IN (\(placeholders));") { statement in
                for (offset, id) in chunk.enumerated() {
                    guard bindText(id.uuidString, to: statement, index: Int32(offset + 1)) else {
                        throw sqliteError(message: "Failed to bind deletion ID")
                    }
                }
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw sqliteError(message: "Failed to delete \(table) rows")
                }
            }
        }
    }

    private func storedFrame(from metadata: FrameMetadata) -> StoredFrame {
        StoredFrame(
            id: metadata.id,
            timestamp: metadata.timestamp,
            hash: metadata.hash,
            displayID: metadata.displayID,
            displayName: metadata.displayName
        )
    }

    private func decodeOptionalUUID(from statement: OpaquePointer, column: Int32) throws -> UUID? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        guard let raw = sqlite3_column_text(statement, column),
              let decoded = UUID(uuidString: String(cString: raw)) else {
            throw FrameDatabaseError.corrupt("Invalid UUID in frame database")
        }
        return decoded
    }

    private func decodeMetadata(from statement: OpaquePointer, offset: Int32 = 0) throws -> FrameMetadata {
        guard let rawID = sqlite3_column_text(statement, offset),
              let id = UUID(uuidString: String(cString: rawID)) else {
            throw FrameDatabaseError.corrupt("Invalid frame ID in frame database")
        }
        let timestampValue = sqlite3_column_double(statement, offset + 1)
        guard timestampValue.isFinite else {
            throw FrameDatabaseError.corrupt("Invalid timestamp in frame database")
        }
        guard sqlite3_column_bytes(statement, offset + 2) == MemoryLayout<UInt64>.size,
              let hashBytes = sqlite3_column_blob(statement, offset + 2) else {
            throw FrameDatabaseError.corrupt("Invalid perceptual hash in frame database")
        }
        var encodedHash: UInt64 = 0
        memcpy(&encodedHash, hashBytes, MemoryLayout<UInt64>.size)

        guard let rawFilename = sqlite3_column_text(statement, offset + 3),
              let rawThumbnailFilename = sqlite3_column_text(statement, offset + 4) else {
            throw FrameDatabaseError.corrupt("Missing frame filename in frame database")
        }
        let filename = String(cString: rawFilename)
        let thumbnailFilename = String(cString: rawThumbnailFilename)
        guard FrameStoreFilename.isSafe(filename),
              FrameStoreFilename.isSafe(thumbnailFilename) else {
            throw FrameDatabaseError.corrupt("Unsafe frame filename in frame database")
        }

        let fileSize = sqlite3_column_int64(statement, offset + 5)
        guard fileSize >= 0 else {
            throw FrameDatabaseError.corrupt("Invalid frame size in frame database")
        }

        let displayID: UUID?
        if sqlite3_column_type(statement, offset + 6) == SQLITE_NULL {
            displayID = nil
        } else {
            guard let rawDisplayID = sqlite3_column_text(statement, offset + 6),
                  let decoded = UUID(uuidString: String(cString: rawDisplayID)) else {
                throw FrameDatabaseError.corrupt("Invalid display ID in frame database")
            }
            displayID = decoded
        }

        let displayName = sqlite3_column_text(statement, offset + 7).map { String(cString: $0) }
        return FrameMetadata(
            id: id,
            timestamp: Date(timeIntervalSince1970: timestampValue),
            hash: UInt64(bigEndian: encodedHash),
            filename: filename,
            thumbnailFilename: thumbnailFilename,
            fileSize: fileSize,
            displayID: displayID,
            displayName: displayName
        )
    }

    private func withTransaction(
        operation: DurablePersistenceOperation? = nil,
        _ body: () throws -> Void
    ) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try body()
            try execute("COMMIT;")
            if let operation {
                try durableCommitHook?(operation)
            }
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard let db else { throw FrameDatabaseError.sqlite("Frame database is closed") }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError(message: "SQL execution failed: \(sql)")
        }
    }

    private func withPreparedStatement<T>(
        _ sql: String,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        guard let db else { throw FrameDatabaseError.sqlite("Frame database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError(message: "Failed to prepare SQL: \(sql)")
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func bindText(_ value: String, to statement: OpaquePointer, index: Int32) -> Bool {
        value.withCString { valuePointer in
            sqlite3_bind_text(statement, index, valuePointer, -1, Self.sqliteTransient) == SQLITE_OK
        }
    }

    private func bindOptionalText(_ value: String?, to statement: OpaquePointer, index: Int32) -> Bool {
        guard let value else {
            return sqlite3_bind_null(statement, index) == SQLITE_OK
        }
        return bindText(value, to: statement, index: index)
    }

    private func bindHash(_ value: UInt64, to statement: OpaquePointer, index: Int32) -> Bool {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(bytes.count),
                Self.sqliteTransient
            ) == SQLITE_OK
        }
    }

    private func requireDone(_ statement: OpaquePointer, message: String) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError(message: message)
        }
    }

    private static func sqliteError(message: String, on db: OpaquePointer?) -> FrameDatabaseError {
        guard let db, let text = sqlite3_errmsg(db) else {
            return .sqlite(message)
        }
        return .sqlite("\(message) (\(String(cString: text)))")
    }

    private func sqliteError(message: String) -> FrameDatabaseError {
        Self.sqliteError(message: message, on: db)
    }
}

nonisolated enum FrameStoreFilename {
    private static let reservedNames = Set(
        [
            ".store-id",
            ".store.lock",
            "frames",
            "frames.sqlite",
            "frames.sqlite-journal",
            "frames.sqlite-wal",
            "frames.sqlite-shm",
            "manifest.json",
            "manifest.json.migrated",
            "recovery"
        ]
    )

    static func collisionKey(_ filename: String) -> String {
        filename.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func isSafe(_ filename: String) -> Bool {
        guard !filename.isEmpty,
              filename != ".",
              filename != "..",
              !filename.utf8.contains(0),
              filename == (filename as NSString).lastPathComponent,
              !reservedNames.contains(collisionKey(filename)) else {
            return false
        }
        return true
    }
}
