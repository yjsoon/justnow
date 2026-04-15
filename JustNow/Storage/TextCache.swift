//
//  TextCache.swift
//  JustNow
//

import Foundation
import SQLite3
import os.log

enum TextCacheError: Error {
    case sqlite(String)
}

/// Caches OCR-extracted text for frames to speed up subsequent searches
actor TextCache {
    nonisolated private static let logger = Logger(subsystem: "sg.tk.JustNow", category: "TextCache")
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
            Self.logger.info("Text cache ready with \(Self.countRows(in: connection)) entries")

            Task { [weak self] in
                await self?.migrateLegacyCacheIfNeeded()
            }
        } catch {
            Self.logger.error("Failed to initialise text cache: \(error.localizedDescription)")
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
        try? withPreparedStatement("SELECT text FROM frame_text WHERE frame_id = ? LIMIT 1;") { statement in
            guard bindFrameID(frameID, to: statement),
                  sqlite3_step(statement) == SQLITE_ROW,
                  let cText = sqlite3_column_text(statement, 0) else {
                return nil
            }

            return String(cString: cText)
        }
    }

    func getSearchLayout(for frameID: UUID) -> SearchTextLayout? {
        try? withPreparedStatement(
            "SELECT layout_json FROM frame_search_layout WHERE frame_id = ? LIMIT 1;"
        ) { statement in
            guard bindFrameID(frameID, to: statement),
                  sqlite3_step(statement) == SQLITE_ROW,
                  let cText = sqlite3_column_text(statement, 0) else {
                return nil
            }

            let json = String(cString: cText)
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(SearchTextLayout.self, from: data)
        }
    }

    /// Cache extracted text for a frame
    func setText(_ text: String, for frameID: UUID, timestamp: Date = Date()) {
        do {
            try withTransaction {
                try withPreparedStatement(
                    """
                    INSERT INTO frame_text (frame_id, timestamp, text)
                    VALUES (?, ?, ?)
                    ON CONFLICT(frame_id) DO UPDATE SET
                        timestamp = excluded.timestamp,
                        text = excluded.text;
                    """
                ) { upsert in
                    guard bindFrameID(frameID, to: upsert, index: 1),
                          bindDouble(timestamp.timeIntervalSince1970, to: upsert, index: 2),
                          bindText(text, to: upsert, index: 3),
                          sqlite3_step(upsert) == SQLITE_DONE else {
                        throw sqliteError(message: "Failed to upsert OCR text")
                    }
                }

                try withPreparedStatement("DELETE FROM frame_text_fts WHERE frame_id = ?;") { deleteFTS in
                    guard bindFrameID(frameID, to: deleteFTS),
                          sqlite3_step(deleteFTS) == SQLITE_DONE else {
                        throw sqliteError(message: "Failed to delete prior FTS entry")
                    }
                }

                try withPreparedStatement("INSERT INTO frame_text_fts(frame_id, text) VALUES (?, ?);") { insertFTS in
                    guard bindFrameID(frameID, to: insertFTS, index: 1),
                          bindText(text, to: insertFTS, index: 2),
                          sqlite3_step(insertFTS) == SQLITE_DONE else {
                        throw sqliteError(message: "Failed to insert FTS row")
                    }
                }
            }
        } catch {
            Self.logger.error("Failed to cache OCR text: \(error.localizedDescription)")
        }
    }

    func setSearchLayout(_ layout: SearchTextLayout, for frameID: UUID, timestamp: Date = Date()) {
        do {
            let data = try JSONEncoder().encode(layout)
            guard let json = String(data: data, encoding: .utf8) else {
                throw sqliteError(message: "Failed to encode search layout JSON")
            }

            try withTransaction {
                try withPreparedStatement(
                    """
                    INSERT INTO frame_search_layout (frame_id, updated_at, layout_json)
                    VALUES (?, ?, ?)
                    ON CONFLICT(frame_id) DO UPDATE SET
                        updated_at = excluded.updated_at,
                        layout_json = excluded.layout_json;
                    """
                ) { upsert in
                    guard bindFrameID(frameID, to: upsert, index: 1),
                          bindDouble(timestamp.timeIntervalSince1970, to: upsert, index: 2),
                          bindText(json, to: upsert, index: 3),
                          sqlite3_step(upsert) == SQLITE_DONE else {
                        throw sqliteError(message: "Failed to upsert search layout")
                    }
                }
            }
        } catch {
            Self.logger.error("Failed to cache search layout: \(error.localizedDescription)")
        }
    }

    func removeText(for frameID: UUID) {
        do {
            try delete(frameIDs: [frameID])
        } catch {
            Self.logger.error("Failed to remove OCR text: \(error.localizedDescription)")
        }
    }

    /// Check if a frame has cached text
    func hasCachedText(for frameID: UUID) -> Bool {
        (try? withPreparedStatement("SELECT 1 FROM frame_text WHERE frame_id = ? LIMIT 1;") { statement in
            guard bindFrameID(frameID, to: statement) else {
                return false
            }

            return sqlite3_step(statement) == SQLITE_ROW
        }) ?? false
    }

    /// Return IDs that already have indexed text
    func cachedFrameIDs(in frameIDs: [UUID]) -> Set<UUID> {
        guard !frameIDs.isEmpty else { return [] }

        var cached: Set<UUID> = []
        for chunk in chunked(frameIDs, size: Self.inClauseChunkSize) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = "SELECT frame_id FROM frame_text WHERE frame_id IN (\(placeholders));"
            try? withPreparedStatement(sql) { statement in
                guard bindFrameIDs(chunk, to: statement) else { return }

                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let cText = sqlite3_column_text(statement, 0) else { continue }
                    let raw = String(cString: cText)
                    if let id = UUID(uuidString: raw) {
                        cached.insert(id)
                    }
                }
            }
        }

        return cached
    }

    /// Search indexed OCR text and return matching frame IDs ordered by recency.
    func searchFrameIDs(matching query: String, limit: Int, since: Date? = nil) -> [UUID] {
        guard limit > 0 else {
            return []
        }

        let safeLimit = Int32(clamping: limit)
        let sinceEpoch = since?.timeIntervalSince1970

        var ids: [UUID] = []

        if let matchQuery = ftsQuery(from: query) {
            try? withPreparedStatement(
                sinceEpoch == nil
                    ?
                    """
                   SELECT frame_text.frame_id
                   FROM frame_text_fts
                   JOIN frame_text ON frame_text.frame_id = frame_text_fts.frame_id
                   WHERE frame_text_fts MATCH ?
                   ORDER BY frame_text.timestamp DESC
                   LIMIT ?;
                   """
                   :
                   """
                   SELECT frame_text.frame_id
                   FROM frame_text_fts
                   JOIN frame_text ON frame_text.frame_id = frame_text_fts.frame_id
                   WHERE frame_text_fts MATCH ?
                     AND frame_text.timestamp >= ?
                   ORDER BY frame_text.timestamp DESC
                   LIMIT ?;
                   """
            ) { statement in
                var bindIndex: Int32 = 1
                var canQuery = bindText(matchQuery, to: statement, index: bindIndex)
                bindIndex += 1

                if canQuery, let sinceEpoch {
                    canQuery = bindDouble(sinceEpoch, to: statement, index: bindIndex)
                    bindIndex += 1
                }

                if canQuery,
                   bindInt32(safeLimit, to: statement, index: bindIndex) {
                    while sqlite3_step(statement) == SQLITE_ROW {
                        guard let cText = sqlite3_column_text(statement, 0) else { continue }
                        let raw = String(cString: cText)
                        if let id = UUID(uuidString: raw) {
                            ids.append(id)
                        }
                    }
                }
            }
        }

        if !ids.isEmpty {
            return ids
        }

        let fallbackSQL =
            sinceEpoch == nil
            ?
            """
            SELECT frame_id
            FROM frame_text
            WHERE instr(lower(text), lower(?)) > 0
            ORDER BY timestamp DESC
            LIMIT ?;
            """
            :
            """
            SELECT frame_id
            FROM frame_text
            WHERE instr(lower(text), lower(?)) > 0
              AND timestamp >= ?
            ORDER BY timestamp DESC
            LIMIT ?;
            """

        guard let fallbackIDs = try? withPreparedStatement(fallbackSQL, { fallback in
            var fallbackIDs: [UUID] = []
            var bindIndex: Int32 = 1
            guard bindText(query, to: fallback, index: bindIndex) else {
                return fallbackIDs
            }
            bindIndex += 1

            if let sinceEpoch {
                guard bindDouble(sinceEpoch, to: fallback, index: bindIndex) else {
                    return fallbackIDs
                }
                bindIndex += 1
            }

            guard bindInt32(safeLimit, to: fallback, index: bindIndex) else {
                return fallbackIDs
            }

            while sqlite3_step(fallback) == SQLITE_ROW {
                guard let cText = sqlite3_column_text(fallback, 0) else { continue }
                let raw = String(cString: cText)
                if let id = UUID(uuidString: raw) {
                    fallbackIDs.append(id)
                }
            }

            return fallbackIDs
        }) else {
            return []
        }

        return fallbackIDs
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
            Self.logger.info("Pruned \(staleIDs.count) stale OCR cache entries")
        } catch {
            Self.logger.error("Failed to prune OCR cache: \(error.localizedDescription)")
        }
    }

    /// Clear all cached text
    func clear() {
        do {
            try withTransaction {
                try execute("DELETE FROM frame_search_layout;")
                try execute("DELETE FROM frame_text_fts;")
                try execute("DELETE FROM frame_text;")
            }
        } catch {
            Self.logger.error("Failed to clear OCR cache: \(error.localizedDescription)")
        }
    }

    var count: Int {
        (try? withPreparedStatement("SELECT COUNT(*) FROM frame_text;") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }) ?? 0
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
        try execute(
            """
            CREATE TABLE IF NOT EXISTS frame_search_layout (
                frame_id TEXT PRIMARY KEY,
                updated_at REAL NOT NULL,
                layout_json TEXT NOT NULL
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
        (try? withPreparedStatement("SELECT COUNT(*) FROM frame_text;", on: db) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                return 0
            }

            return Int(sqlite3_column_int64(statement, 0))
        }) ?? 0
    }

    private func migrateLegacyCacheIfNeeded() {
        do {
            try migrateLegacyJSONIfNeeded()
        } catch {
            Self.logger.error("Failed to migrate legacy OCR cache: \(error.localizedDescription)")
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
            try withPreparedStatement(
                """
                INSERT INTO frame_text (frame_id, timestamp, text)
                VALUES (?, ?, ?)
                ON CONFLICT(frame_id) DO UPDATE SET
                    timestamp = excluded.timestamp,
                    text = excluded.text;
                """
            ) { upsert in
                try withPreparedStatement("INSERT INTO frame_text_fts(frame_id, text) VALUES (?, ?);") { insertFTS in
                    for (id, text) in legacy {
                        reset(upsert)
                        guard bindFrameID(id, to: upsert, index: 1),
                              bindDouble(migrationTimestamp, to: upsert, index: 2),
                              bindText(text, to: upsert, index: 3),
                              sqlite3_step(upsert) == SQLITE_DONE else {
                            throw sqliteError(message: "Failed to migrate legacy cache row")
                        }

                        reset(insertFTS)
                        guard bindFrameID(id, to: insertFTS, index: 1),
                              bindText(text, to: insertFTS, index: 2),
                              sqlite3_step(insertFTS) == SQLITE_DONE else {
                            throw sqliteError(message: "Failed to migrate legacy FTS row")
                        }
                    }
                }
            }
        }

        Self.logger.info("Migrated \(legacy.count) legacy OCR cache entries into SQLite")
    }

    private func delete(frameIDs: [UUID]) throws {
        guard !frameIDs.isEmpty else { return }

        for chunk in chunked(frameIDs, size: Self.inClauseChunkSize) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try withTransaction {
                let deletePrimarySQL = "DELETE FROM frame_text WHERE frame_id IN (\(placeholders));"
                let deleteFTSSQL = "DELETE FROM frame_text_fts WHERE frame_id IN (\(placeholders));"
                let deleteLayoutSQL = "DELETE FROM frame_search_layout WHERE frame_id IN (\(placeholders));"
                try withPreparedStatement(deletePrimarySQL) { deletePrimary in
                    guard bindFrameIDs(chunk, to: deletePrimary) else {
                        throw sqliteError(message: "Failed binding primary delete frame ID")
                    }
                    guard sqlite3_step(deletePrimary) == SQLITE_DONE else {
                        throw sqliteError(message: "Failed deleting primary rows")
                    }
                }
                try withPreparedStatement(deleteFTSSQL) { deleteFTS in
                    guard bindFrameIDs(chunk, to: deleteFTS) else {
                        throw sqliteError(message: "Failed binding FTS delete frame ID")
                    }
                    guard sqlite3_step(deleteFTS) == SQLITE_DONE else {
                        throw sqliteError(message: "Failed deleting FTS rows")
                    }
                }
                try withPreparedStatement(deleteLayoutSQL) { deleteLayout in
                    guard bindFrameIDs(chunk, to: deleteLayout) else {
                        throw sqliteError(message: "Failed binding search layout delete frame ID")
                    }
                    guard sqlite3_step(deleteLayout) == SQLITE_DONE else {
                        throw sqliteError(message: "Failed deleting search layout rows")
                    }
                }
            }
        }
    }

    private func allCachedFrameIDs() throws -> [UUID] {
        try withPreparedStatement("SELECT frame_id FROM frame_text;") { statement in
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

    private static func withPreparedStatement<T>(
        _ sql: String,
        on db: OpaquePointer,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        let statement = try prepare(sql, on: db)
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func withPreparedStatement<T>(
        _ sql: String,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        guard let db else { throw sqliteError(message: "Database is not open") }
        return try Self.withPreparedStatement(sql, on: db, body)
    }

    private static func prepare(_ sql: String, on db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError(message: "Failed to prepare SQL: \(sql)", on: db)
        }
        return statement
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw sqliteError(message: "Database is not open") }
        return try Self.prepare(sql, on: db)
    }

    private func reset(_ statement: OpaquePointer) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    private func bindFrameID(_ frameID: UUID, to statement: OpaquePointer, index: Int32 = 1) -> Bool {
        bindText(frameID.uuidString, to: statement, index: index)
    }

    private func bindFrameIDs(_ frameIDs: [UUID], to statement: OpaquePointer, startingAt index: Int32 = 1) -> Bool {
        var bindIndex = index
        for frameID in frameIDs {
            guard bindFrameID(frameID, to: statement, index: bindIndex) else {
                return false
            }
            bindIndex += 1
        }
        return true
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
        let tokens = SearchQueryTokeniser.tokens(from: query)
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
