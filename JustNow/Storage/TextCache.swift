//
//  TextCache.swift
//  JustNow
//

import Foundation
import SQLite3
import os.log

private let logger = Logger(subsystem: "sg.tk.JustNow", category: "TextCache")

enum TextCacheError: Error {
    case sqlite(String)
}

/// Caches OCR-extracted text for frames to speed up subsequent searches
actor TextCache {
    private let databaseURL: URL
    private let legacyCacheURL: URL
    private var db: OpaquePointer?

    private static let inClauseChunkSize = 400
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("JustNow", isDirectory: true)
        self.databaseURL = appDir.appendingPathComponent("text_cache.sqlite")
        self.legacyCacheURL = appDir.appendingPathComponent("text_cache.json")

        do {
            try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            let connection = try Self.openDatabase(at: databaseURL)
            db = connection
            try Self.createSchema(on: connection)
            try Self.repairIndex(on: connection)
            logger.info("Text cache ready with \(Self.countRows(in: connection)) entries")

            Task { [weak self] in
                await self?.migrateLegacyCacheIfNeeded()
            }
        } catch {
            logger.error("Failed to initialise text cache: \(error.localizedDescription)")
            if let db {
                sqlite3_close(db)
                self.db = nil
            }
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    /// Get cached text for a frame, returns nil if not cached
    func getText(for frameID: UUID) -> String? {
        guard let statement = try? prepare("SELECT text FROM frame_text WHERE frame_id = ? LIMIT 1;") else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard bindText(frameID.uuidString, to: statement, index: 1),
              sqlite3_step(statement) == SQLITE_ROW,
              let cText = sqlite3_column_text(statement, 0) else {
            return nil
        }

        return String(cString: cText)
    }

    /// Cache extracted text for a frame
    func setText(_ text: String, for frameID: UUID, timestamp: Date = Date()) {
        do {
            try withTransaction {
                guard let upsert = try? prepare(
                    """
                    INSERT INTO frame_text (frame_id, timestamp, text)
                    VALUES (?, ?, ?)
                    ON CONFLICT(frame_id) DO UPDATE SET
                        timestamp = excluded.timestamp,
                        text = excluded.text;
                    """
                ) else {
                    throw sqliteError(message: "Failed to prepare upsert statement")
                }
                defer { sqlite3_finalize(upsert) }

                guard bindText(frameID.uuidString, to: upsert, index: 1),
                      bindDouble(timestamp.timeIntervalSince1970, to: upsert, index: 2),
                      bindText(text, to: upsert, index: 3),
                      sqlite3_step(upsert) == SQLITE_DONE else {
                    throw sqliteError(message: "Failed to upsert OCR text")
                }

                guard let deleteFTS = try? prepare("DELETE FROM frame_text_fts WHERE frame_id = ?;") else {
                    throw sqliteError(message: "Failed to prepare FTS delete statement")
                }
                defer { sqlite3_finalize(deleteFTS) }

                guard bindText(frameID.uuidString, to: deleteFTS, index: 1),
                      sqlite3_step(deleteFTS) == SQLITE_DONE else {
                    throw sqliteError(message: "Failed to delete prior FTS entry")
                }

                guard let insertFTS = try? prepare("INSERT INTO frame_text_fts(frame_id, text) VALUES (?, ?);") else {
                    throw sqliteError(message: "Failed to prepare FTS insert statement")
                }
                defer { sqlite3_finalize(insertFTS) }

                guard bindText(frameID.uuidString, to: insertFTS, index: 1),
                      bindText(text, to: insertFTS, index: 2),
                      sqlite3_step(insertFTS) == SQLITE_DONE else {
                    throw sqliteError(message: "Failed to insert FTS row")
                }
            }
        } catch {
            logger.error("Failed to cache OCR text: \(error.localizedDescription)")
        }
    }

    /// Check if a frame has cached text
    func hasCachedText(for frameID: UUID) -> Bool {
        guard let statement = try? prepare("SELECT 1 FROM frame_text WHERE frame_id = ? LIMIT 1;") else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        guard bindText(frameID.uuidString, to: statement, index: 1) else {
            return false
        }

        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Return IDs that already have indexed text
    func cachedFrameIDs(in frameIDs: [UUID]) -> Set<UUID> {
        guard !frameIDs.isEmpty else { return [] }

        var cached: Set<UUID> = []
        for chunk in chunked(frameIDs, size: Self.inClauseChunkSize) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = "SELECT frame_id FROM frame_text WHERE frame_id IN (\(placeholders));"
            guard let statement = try? prepare(sql) else { continue }
            defer { sqlite3_finalize(statement) }

            var bindIndex: Int32 = 1
            for frameID in chunk {
                guard bindText(frameID.uuidString, to: statement, index: bindIndex) else {
                    break
                }
                bindIndex += 1
            }

            while sqlite3_step(statement) == SQLITE_ROW {
                guard let cText = sqlite3_column_text(statement, 0) else { continue }
                let raw = String(cString: cText)
                if let id = UUID(uuidString: raw) {
                    cached.insert(id)
                }
            }
        }

        return cached
    }

    /// Search indexed OCR text and return matching frame IDs, ranked by relevance then recency.
    func searchFrameIDs(matching query: String, limit: Int) -> [UUID] {
        guard limit > 0 else {
            return []
        }

        var ids: [UUID] = []

        if let matchQuery = ftsQuery(from: query),
           let statement = try? prepare(
               """
               SELECT frame_text.frame_id
               FROM frame_text_fts
               JOIN frame_text ON frame_text.frame_id = frame_text_fts.frame_id
               WHERE frame_text_fts MATCH ?
               ORDER BY bm25(frame_text_fts), frame_text.timestamp DESC
               LIMIT ?;
               """
           ) {
            defer { sqlite3_finalize(statement) }

            if bindText(matchQuery, to: statement, index: 1),
               bindInt32(Int32(limit), to: statement, index: 2) {
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let cText = sqlite3_column_text(statement, 0) else { continue }
                    let raw = String(cString: cText)
                    if let id = UUID(uuidString: raw) {
                        ids.append(id)
                    }
                }
            }
        }

        if !ids.isEmpty {
            return ids
        }

        guard let fallback = try? prepare(
            """
            SELECT frame_id
            FROM frame_text
            WHERE instr(lower(text), lower(?)) > 0
            ORDER BY timestamp DESC
            LIMIT ?;
            """
        ) else {
            return []
        }
        defer { sqlite3_finalize(fallback) }

        guard bindText(query, to: fallback, index: 1),
              bindInt32(Int32(limit), to: fallback, index: 2) else {
            return []
        }

        while sqlite3_step(fallback) == SQLITE_ROW {
            guard let cText = sqlite3_column_text(fallback, 0) else { continue }
            let raw = String(cString: cText)
            if let id = UUID(uuidString: raw) {
                ids.append(id)
            }
        }

        return ids
    }

    /// Save cache to disk (call periodically or on app termination)
    func save() {
        // No-op: SQLite writes are committed transactionally.
    }

    /// Remove cached text for frames that no longer exist
    func prune(keepingFrameIDs validIDs: Set<UUID>) {
        do {
            let allIDs = try allCachedFrameIDs()
            let staleIDs = allIDs.filter { !validIDs.contains($0) }
            guard !staleIDs.isEmpty else { return }

            try delete(frameIDs: staleIDs)
            logger.info("Pruned \(staleIDs.count) stale OCR cache entries")
        } catch {
            logger.error("Failed to prune OCR cache: \(error.localizedDescription)")
        }
    }

    /// Clear all cached text
    func clear() {
        do {
            try withTransaction {
                try execute("DELETE FROM frame_text_fts;")
                try execute("DELETE FROM frame_text;")
            }
        } catch {
            logger.error("Failed to clear OCR cache: \(error.localizedDescription)")
        }
    }

    var count: Int {
        guard let statement = try? prepare("SELECT COUNT(*) FROM frame_text;") else {
            return 0
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: - SQLite Helpers

    private static func openDatabase(at databaseURL: URL) throws -> OpaquePointer {
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &connection, flags, nil) == SQLITE_OK,
              let connection else {
            throw sqliteError(message: "Failed to open text cache database", on: connection)
        }

        try execute("PRAGMA journal_mode=WAL;", on: connection)
        try execute("PRAGMA synchronous=NORMAL;", on: connection)
        try execute("PRAGMA temp_store=MEMORY;", on: connection)

        return connection
    }

    private static func createSchema(on db: OpaquePointer) throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS frame_text (
                frame_id TEXT PRIMARY KEY,
                timestamp REAL NOT NULL,
                text TEXT NOT NULL
            );
            """
            ,
            on: db
        )
        try execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS frame_text_fts USING fts5(
                frame_id UNINDEXED,
                text,
                tokenize = 'unicode61 remove_diacritics 2'
            );
            """
            ,
            on: db
        )
        try execute("CREATE INDEX IF NOT EXISTS idx_frame_text_timestamp ON frame_text(timestamp DESC);", on: db)
    }

    private static func repairIndex(on db: OpaquePointer) throws {
        try execute("DELETE FROM frame_text_fts;", on: db)
        try execute("INSERT INTO frame_text_fts(frame_id, text) SELECT frame_id, text FROM frame_text;", on: db)
    }

    private static func countRows(in db: OpaquePointer) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM frame_text;", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return 0
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }

        return Int(sqlite3_column_int64(statement, 0))
    }

    private func migrateLegacyCacheIfNeeded() {
        do {
            try migrateLegacyJSONIfNeeded()
        } catch {
            logger.error("Failed to migrate legacy OCR cache: \(error.localizedDescription)")
        }
    }

    private func migrateLegacyJSONIfNeeded() throws {
        guard count == 0,
              FileManager.default.fileExists(atPath: legacyCacheURL.path),
              let data = try? Data(contentsOf: legacyCacheURL),
              let legacy = try? JSONDecoder().decode([UUID: String].self, from: data),
              !legacy.isEmpty else {
            return
        }

        let migrationTimestamp = Date.distantPast.timeIntervalSince1970
        try withTransaction {
            guard let upsert = try? prepare(
                """
                INSERT INTO frame_text (frame_id, timestamp, text)
                VALUES (?, ?, ?)
                ON CONFLICT(frame_id) DO UPDATE SET
                    timestamp = excluded.timestamp,
                    text = excluded.text;
                """
            ) else {
                throw sqliteError(message: "Failed to prepare legacy upsert statement")
            }
            defer { sqlite3_finalize(upsert) }

            guard let insertFTS = try? prepare("INSERT INTO frame_text_fts(frame_id, text) VALUES (?, ?);") else {
                throw sqliteError(message: "Failed to prepare legacy FTS insert statement")
            }
            defer { sqlite3_finalize(insertFTS) }

            for (id, text) in legacy {
                sqlite3_reset(upsert)
                sqlite3_clear_bindings(upsert)
                guard bindText(id.uuidString, to: upsert, index: 1),
                      bindDouble(migrationTimestamp, to: upsert, index: 2),
                      bindText(text, to: upsert, index: 3),
                      sqlite3_step(upsert) == SQLITE_DONE else {
                    throw sqliteError(message: "Failed to migrate legacy cache row")
                }

                sqlite3_reset(insertFTS)
                sqlite3_clear_bindings(insertFTS)
                guard bindText(id.uuidString, to: insertFTS, index: 1),
                      bindText(text, to: insertFTS, index: 2),
                      sqlite3_step(insertFTS) == SQLITE_DONE else {
                    throw sqliteError(message: "Failed to migrate legacy FTS row")
                }
            }
        }

        logger.info("Migrated \(legacy.count) legacy OCR cache entries into SQLite")
    }

    private func delete(frameIDs: [UUID]) throws {
        guard !frameIDs.isEmpty else { return }

        for chunk in chunked(frameIDs, size: Self.inClauseChunkSize) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try withTransaction {
                let deletePrimarySQL = "DELETE FROM frame_text WHERE frame_id IN (\(placeholders));"
                guard let deletePrimary = try? prepare(deletePrimarySQL) else {
                    throw sqliteError(message: "Failed to prepare primary delete statement")
                }
                defer { sqlite3_finalize(deletePrimary) }

                let deleteFTSSQL = "DELETE FROM frame_text_fts WHERE frame_id IN (\(placeholders));"
                guard let deleteFTS = try? prepare(deleteFTSSQL) else {
                    throw sqliteError(message: "Failed to prepare FTS delete statement")
                }
                defer { sqlite3_finalize(deleteFTS) }

                var bindIndex: Int32 = 1
                for frameID in chunk {
                    guard bindText(frameID.uuidString, to: deletePrimary, index: bindIndex) else {
                        throw sqliteError(message: "Failed binding primary delete frame ID")
                    }
                    bindIndex += 1
                }
                guard sqlite3_step(deletePrimary) == SQLITE_DONE else {
                    throw sqliteError(message: "Failed deleting primary rows")
                }

                bindIndex = 1
                for frameID in chunk {
                    guard bindText(frameID.uuidString, to: deleteFTS, index: bindIndex) else {
                        throw sqliteError(message: "Failed binding FTS delete frame ID")
                    }
                    bindIndex += 1
                }
                guard sqlite3_step(deleteFTS) == SQLITE_DONE else {
                    throw sqliteError(message: "Failed deleting FTS rows")
                }
            }
        }
    }

    private func allCachedFrameIDs() throws -> [UUID] {
        guard let statement = try? prepare("SELECT frame_id FROM frame_text;") else {
            throw sqliteError(message: "Failed to prepare all IDs query")
        }
        defer { sqlite3_finalize(statement) }

        var ids: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cText = sqlite3_column_text(statement, 0) else { continue }
            let raw = String(cString: cText)
            if let id = UUID(uuidString: raw) {
                ids.append(id)
            }
        }
        return ids
    }

    private func withTransaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private static func execute(_ sql: String, on db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError(message: "SQL execution failed: \(sql)", on: db)
        }
    }

    private func execute(_ sql: String) throws {
        guard let db else { throw sqliteError(message: "Database is not open") }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError(message: "SQL execution failed: \(sql)")
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw sqliteError(message: "Database is not open") }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError(message: "Failed to prepare SQL: \(sql)")
        }
        return statement
    }

    private func bindText(_ value: String, to statement: OpaquePointer, index: Int32) -> Bool {
        value.withCString { cString in
            sqlite3_bind_text(statement, index, cString, -1, Self.sqliteTransient) == SQLITE_OK
        }
    }

    private func bindDouble(_ value: Double, to statement: OpaquePointer, index: Int32) -> Bool {
        sqlite3_bind_double(statement, index, value) == SQLITE_OK
    }

    private func bindInt32(_ value: Int32, to statement: OpaquePointer, index: Int32) -> Bool {
        sqlite3_bind_int(statement, index, value) == SQLITE_OK
    }

    private func ftsQuery(from query: String) -> String? {
        let tokens = query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return nil }

        return tokens
            .map { token in
                let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
            .joined(separator: " AND ")
    }

    private static func sqliteError(message: String, on db: OpaquePointer?) -> TextCacheError {
        guard let db else { return .sqlite(message) }
        if let cText = sqlite3_errmsg(db) {
            return .sqlite("\(message) (\(String(cString: cText)))")
        }
        return .sqlite(message)
    }

    private func sqliteError(message: String) -> TextCacheError {
        Self.sqliteError(message: message, on: db)
    }

    private func chunked(_ frameIDs: [UUID], size: Int) -> [[UUID]] {
        guard size > 0 else { return [frameIDs] }
        var chunks: [[UUID]] = []
        chunks.reserveCapacity((frameIDs.count / size) + 1)

        var start = 0
        while start < frameIDs.count {
            let end = min(start + size, frameIDs.count)
            chunks.append(Array(frameIDs[start..<end]))
            start = end
        }
        return chunks
    }
}
