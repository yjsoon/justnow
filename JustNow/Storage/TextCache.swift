//
//  TextCache.swift
//  JustNow
//

import Foundation
import SQLite3
import os.log

enum TextCacheError: LocalizedError {
    case sqlite(String, code: Int32? = nil)

    var errorDescription: String? {
        switch self {
        case .sqlite(let message, _): message
        }
    }

    var sqliteResultCode: Int32? {
        switch self {
        case .sqlite(_, let code): code
        }
    }
}

typealias TextCacheClearHook = @Sendable () throws -> Void

/// Shared with SQLite's synchronous progress callback so cancellation can
/// interrupt a long-running statement while the actor is busy stepping it.
nonisolated private final class TextCacheQueryCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    let onProgress: (@Sendable () -> Void)?

    init(onProgress: (@Sendable () -> Void)? = nil) {
        self.onProgress = onProgress
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

nonisolated private func textCacheProgressHandler(_ context: UnsafeMutableRawPointer?) -> Int32 {
    guard let context else { return 0 }
    let state = Unmanaged<TextCacheQueryCancellationState>.fromOpaque(context).takeUnretainedValue()
    state.onProgress?()
    return state.isCancelled() ? 1 : 0
}

/// SQLite's built-in lower() only folds ASCII. Keep Unicode matching aligned
/// with Foundation without changing the stored OCR text or FTS tokenizer.
nonisolated private func textCacheUnicodeContains(
    _ context: OpaquePointer?,
    _ argumentCount: Int32,
    _ arguments: UnsafeMutablePointer<OpaquePointer?>?
) {
    guard argumentCount == 2, let arguments,
          let text = sqlite3_value_text(arguments[0]),
          let token = sqlite3_value_text(arguments[1]) else {
        sqlite3_result_int(context, 0)
        return
    }
    let contains = String(cString: text).range(of: String(cString: token), options: .caseInsensitive) != nil
    sqlite3_result_int(context, contains ? 1 : 0)
}

/// Caches OCR-extracted text for frames to speed up subsequent searches
actor TextCache {
    nonisolated private static let logger = Logger(subsystem: "sg.tk.JustNow", category: "TextCache")
    private let databaseURL: URL
    private let legacyCacheURL: URL
    private let clearHook: TextCacheClearHook?
    private var db: OpaquePointer?
    /// Diagnostic seam counting attempted SQLite write transactions. Reads do
    /// not affect it, so tests can prove capture stayed off the OCR database.
    private var mutationTransactionCount = 0
    /// Diagnostic seam counting lazy reconnect attempts after a failed open.
    private var reconnectAttemptCount = 0
    /// Monotonic uptime of the last reconnect attempt (wall-clock Date could
    /// roll back and suppress retries for hours).
    private var lastReconnectAttempt: TimeInterval?

    #if DEBUG
    private var queryProgressHookForTesting: (@Sendable () -> Void)?
    private var substringSearchCount = 0

    func setQueryProgressHookForTesting(_ hook: (@Sendable () -> Void)?) {
        queryProgressHookForTesting = hook
    }

    func substringSearchCountForTesting() -> Int {
        substringSearchCount
    }
    #endif

    private static let inClauseChunkSize = 400
    /// Minimum spacing between lazy reconnect attempts so a persistently
    /// broken store does not retry on every search (including searches
    /// re-triggered by index-status polling).
    private static let reconnectMinimumInterval: TimeInterval = 1
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// `directory` is injectable so tests can run against a temporary
    /// location instead of the live Application Support store.
    init(directory: URL? = nil, clearHook: TextCacheClearHook? = nil) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let appDir = directory ?? appSupport.appendingPathComponent("JustNow", isDirectory: true)
        self.databaseURL = appDir.appendingPathComponent("text_cache.sqlite")
        self.legacyCacheURL = appDir.appendingPathComponent("text_cache.json")
        self.clearHook = clearHook

        do {
            let connection = try Self.openStore(at: databaseURL)
            db = connection
            Self.logger.info("Text cache ready with \(Self.countRows(in: connection)) entries")

            Task { [weak self] in
                await self?.migrateLegacyCacheIfNeeded()
            }
        } catch {
            // Init failure must not crash or block capture startup: the actor
            // still constructs with db == nil and search is simply unavailable
            // until a deliberate search retries the open lazily.
            Self.logger.error("Failed to initialise text cache: \(String(describing: error))")
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
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
                // `frame_id` is unindexed in the FTS table, so deleting an
                // absent entry scans the entire index. The primary table is
                // authoritative: startup repair removes FTS drift, and all
                // normal mutations update both tables in this transaction.
                let hadPriorText = try withPreparedStatement(
                    "SELECT 1 FROM frame_text WHERE frame_id = ? LIMIT 1;"
                ) { statement in
                    guard bindFrameID(frameID, to: statement) else {
                        throw sqliteError(message: "Failed to check existing OCR text")
                    }

                    switch sqlite3_step(statement) {
                    case SQLITE_ROW:
                        return true
                    case SQLITE_DONE:
                        return false
                    default:
                        throw sqliteError(message: "Failed to check existing OCR text")
                    }
                }

                try withPreparedStatement(
                    """
                    INSERT INTO frame_text (frame_id, timestamp, text)
                    VALUES (?, ?, ?)
                    ON CONFLICT(frame_id) DO UPDATE SET
                        timestamp = MAX(frame_text.timestamp, excluded.timestamp),
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

                if hadPriorText {
                    try withPreparedStatement("DELETE FROM frame_text_fts WHERE frame_id = ?;") { deleteFTS in
                        guard bindFrameID(frameID, to: deleteFTS),
                              sqlite3_step(deleteFTS) == SQLITE_DONE else {
                            throw sqliteError(message: "Failed to delete prior FTS entry")
                        }
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

    /// Advances search recency for an already-indexed physical asset without
    /// re-running OCR or rewriting its FTS content.
    func updateTimestamp(for frameID: UUID, timestamp: Date) {
        guard hasCachedRecord(for: frameID) else { return }
        do {
            try withTransaction {
                try withPreparedStatement(
                    "UPDATE frame_text SET timestamp = MAX(timestamp, ?) WHERE frame_id = ?;"
                ) { statement in
                    guard bindDouble(timestamp.timeIntervalSince1970, to: statement, index: 1),
                          bindFrameID(frameID, to: statement, index: 2),
                          sqlite3_step(statement) == SQLITE_DONE else {
                        throw sqliteError(message: "Failed to update OCR text timestamp")
                    }
                }
                try withPreparedStatement(
                    "UPDATE frame_search_layout SET updated_at = MAX(updated_at, ?) WHERE frame_id = ?;"
                ) { statement in
                    guard bindDouble(timestamp.timeIntervalSince1970, to: statement, index: 1),
                          bindFrameID(frameID, to: statement, index: 2),
                          sqlite3_step(statement) == SQLITE_DONE else {
                        throw sqliteError(message: "Failed to update search-layout timestamp")
                    }
                }
            }
        } catch {
            Self.logger.error("Failed to update OCR cache timestamp: \(error.localizedDescription)")
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
                        updated_at = MAX(frame_search_layout.updated_at, excluded.updated_at),
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
        removeText(forFrameIDs: [frameID])
    }

    /// Deletes OCR text, FTS content, and cached layouts for known physical
    /// assets. Unlike `prune(keepingFrameIDs:)`, an empty remaining history is
    /// a valid caller state here.
    func removeText(forFrameIDs frameIDs: Set<UUID>) {
        guard !frameIDs.isEmpty else { return }
        do {
            try delete(frameIDs: Array(frameIDs))
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

    /// Read-only existence check for either cache representation. Repository
    /// checkpoints use it to avoid opening an empty write transaction when a
    /// newly durable frame has not been indexed yet.
    func hasCachedRecord(for frameID: UUID) -> Bool {
        (try? withPreparedStatement(
            """
            SELECT 1 FROM frame_text WHERE frame_id = ?
            UNION ALL
            SELECT 1 FROM frame_search_layout WHERE frame_id = ?
            LIMIT 1;
            """
        ) { statement in
            guard bindFrameID(frameID, to: statement, index: 1),
                  bindFrameID(frameID, to: statement, index: 2) else {
                return false
            }
            return sqlite3_step(statement) == SQLITE_ROW
        }) ?? false
    }

    /// Search indexed OCR text and return matching frame IDs ordered by recency.
    /// Throws when the store is unavailable or a query fails; a genuine empty
    /// match is a successful empty result, never an error.
    func searchFrameIDs(matching query: String, limit: Int, since: Date? = nil) async throws -> [UUID] {
        guard limit > 0 else {
            return []
        }
        try Task.checkCancellation()

        let safeLimit = Int32(clamping: limit)
        let sinceEpoch = since?.timeIntervalSince1970

        let matchQuery = ftsQuery(from: query)
        let originalTokens = query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let literalTokens = originalTokens.filter { !$0.allSatisfy(\.isASCII) }
        let asciiMatchQuery = ftsQuery(from: originalTokens.filter { $0.allSatisfy(\.isASCII) }.joined(separator: " "))

        try reconnectIfNeeded()
        guard db != nil else {
            throw sqliteError(message: "Text cache database is unavailable")
        }

        #if DEBUG
        let cancellation = TextCacheQueryCancellationState(onProgress: queryProgressHookForTesting)
        #else
        let cancellation = TextCacheQueryCancellationState()
        #endif
        do {
            return try await withTaskCancellationHandler(operation: {
                try withQueryCancellation(cancellation) {
                    try searchFrameIDs(
                        query: query,
                        matchQuery: matchQuery,
                        includesSubstringFallback: !literalTokens.isEmpty || matchQuery == nil,
                        literalTokens: literalTokens,
                        asciiMatchQuery: asciiMatchQuery,
                        limit: safeLimit,
                        sinceEpoch: sinceEpoch
                    )
                }
            }, onCancel: {
                cancellation.cancel()
            })
        } catch where cancellation.isCancelled() || Task.isCancelled {
            throw CancellationError()
        }
    }

    /// Remove cached text for frames that no longer exist
    func prune(keepingFrameIDs validIDs: Set<UUID>) {
        // An empty valid set is almost always an upstream failure (e.g. a
        // quarantined manifest), not a request to wipe the whole index —
        // wholesale wipes must go through `clear()`. Stale entries merely
        // linger until the next prune with a non-empty set.
        guard !validIDs.isEmpty else { return }

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
    func clear() throws {
        try clearHook?()
        try withTransaction {
            try execute("DELETE FROM frame_search_layout;")
            try execute("DELETE FROM frame_text_fts;")
            try execute("DELETE FROM frame_text;")
        }
        let remainingRows = try ["frame_search_layout", "frame_text_fts", "frame_text"].reduce(0) {
            partialResult, table in
            try partialResult + withPreparedStatement("SELECT COUNT(*) FROM \(table);") { statement in
                guard sqlite3_step(statement) == SQLITE_ROW else {
                    throw sqliteError(message: "Failed to verify OCR cache clear")
                }
                return Int(sqlite3_column_int64(statement, 0))
            }
        }
        guard remainingRows == 0 else {
            throw TextCacheError.sqlite(
                "OCR cache clear verification found \(remainingRows) remaining row(s)"
            )
        }
    }

    var count: Int {
        (try? withPreparedStatement("SELECT COUNT(*) FROM frame_text;") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }) ?? 0
    }

    func mutationTransactionCountForTesting() -> Int {
        mutationTransactionCount
    }

    func reconnectAttemptCountForTesting() -> Int {
        reconnectAttemptCount
    }

    /// A failed init leaves `db` nil; a deliberate search retries the same
    /// open/schema/repair sequence once per call, throttled by
    /// `reconnectMinimumInterval` so a persistently broken store does not
    /// retry unboundedly on every search (including searches re-triggered by
    /// index-status polling). Non-search calls such as count/hasCachedText/
    /// setText/hasCachedRecord deliberately do not reconnect: they run on the
    /// capture path where a reconnect attempt per frame would stall writes.
    private func reconnectIfNeeded() throws {
        guard db == nil else { return }
        if let lastReconnectAttempt,
           ProcessInfo.processInfo.systemUptime - lastReconnectAttempt < Self.reconnectMinimumInterval {
            throw sqliteError(message: "Text cache database is unavailable")
        }
        reconnectAttemptCount += 1
        lastReconnectAttempt = ProcessInfo.processInfo.systemUptime
        let connection = try Self.openStore(at: databaseURL)
        db = connection
        Self.logger.info("Text cache reconnected with \(Self.countRows(in: connection)) entries")
        Task { [weak self] in
            await self?.migrateLegacyCacheIfNeeded()
        }
    }

    // MARK: - SQLite Helpers

    /// Runs the shared directory-create/open/schema/repair sequence used
    /// by init and lazy reconnect so both recover from the same triggers
    /// (including a file blocking the cache directory). On any failure the
    /// provisional handle is closed so no connection leaks and the caller
    /// is left with db == nil.
    private static func openStore(at databaseURL: URL) throws -> OpaquePointer {
        let appDir = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: appDir,
            withIntermediateDirectories: true,
            attributes: PrivateStorageProtection.ownerOnlyDirectoryAttributes
        )
        PrivateStorageProtection.apply(to: appDir)
        let connection = try openDatabase(at: databaseURL)
        do {
            guard sqlite3_create_function_v2(
                connection, "unicode_contains", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC,
                nil, textCacheUnicodeContains, nil, nil, nil
            ) == SQLITE_OK else {
                throw sqliteError(message: "Failed to register Unicode text search", on: connection)
            }
            try createSchema(on: connection)
            try repairIndexIfNeeded(on: connection)
        } catch {
            sqlite3_close(connection)
            throw error
        }
        return connection
    }

    private static func openDatabase(at databaseURL: URL) throws -> OpaquePointer {
        try FrameStoreFile.requireNotSymbolicLink(
            at: databaseURL,
            description: "text cache database"
        )
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &connection, flags, nil) == SQLITE_OK,
              let connection else {
            // sqlite3_open_v2 may still hand back a handle on failure:
            // capture the error message before closing so it cannot leak.
            let error = sqliteError(message: "Failed to open text cache database", on: connection)
            if let connection {
                sqlite3_close(connection)
            }
            throw error
        }

        // A closing connection checkpoints the WAL under an exclusive lock;
        // without a busy timeout, opening a new connection during that window
        // fails instantly and permanently disables the cache for the session.
        sqlite3_busy_timeout(connection, 2000)

        do {
            try execute("PRAGMA journal_mode=WAL;", on: connection)
            try execute("PRAGMA synchronous=NORMAL;", on: connection)
            try execute("PRAGMA temp_store=MEMORY;", on: connection)
        } catch {
            // The provisional handle is not visible to callers yet; close it
            // here so a pragma failure cannot leak the connection.
            sqlite3_close(connection)
            throw error
        }

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

    /// FTS5 maintains its own durable inverted index; routine rebuilds are
    /// unnecessary and quadratic with history size. Rebuild only when the FTS
    /// table drifts from the primary table, including same-count missing or
    /// duplicate rows.
    private static func repairIndexIfNeeded(on db: OpaquePointer) throws {
        let primaryCount = (try? withPreparedStatement("SELECT COUNT(*) FROM frame_text;", on: db) { statement in
            sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
        }) ?? 0

        let ftsCount = (try? withPreparedStatement("SELECT COUNT(*) FROM frame_text_fts;", on: db) { statement in
            sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
        }) ?? 0

        let missingFromFTS = (try? hasRows(
            "SELECT frame_id FROM frame_text EXCEPT SELECT frame_id FROM frame_text_fts LIMIT 1;",
            on: db
        )) ?? true
        let staleInFTS = (try? hasRows(
            "SELECT frame_id FROM frame_text_fts EXCEPT SELECT frame_id FROM frame_text LIMIT 1;",
            on: db
        )) ?? true
        let staleTextInFTS = (try? hasRows(
            """
            SELECT frame_text.frame_id
            FROM frame_text
            JOIN frame_text_fts ON frame_text.frame_id = frame_text_fts.frame_id
            WHERE frame_text.text <> frame_text_fts.text
            LIMIT 1;
            """,
            on: db
        )) ?? true

        guard primaryCount != ftsCount || missingFromFTS || staleInFTS || staleTextInFTS else { return }

        Self.logger.info("Repairing FTS index (primary=\(primaryCount), fts=\(ftsCount))")
        try execute("DELETE FROM frame_text_fts;", on: db)
        try execute("INSERT INTO frame_text_fts(frame_id, text) SELECT frame_id, text FROM frame_text;", on: db)
    }

    private static func hasRows(_ sql: String, on db: OpaquePointer) throws -> Bool {
        try withPreparedStatement(sql, on: db) { statement in
            sqlite3_step(statement) == SQLITE_ROW
        }
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
        mutationTransactionCount += 1
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

    private func withQueryCancellation<T>(
        _ cancellation: TextCacheQueryCancellationState,
        _ body: () throws -> T
    ) throws -> T {
        guard let db else { throw sqliteError(message: "Database is not open") }
        sqlite3_progress_handler(
            db,
            1_000,
            textCacheProgressHandler,
            Unmanaged.passUnretained(cancellation).toOpaque()
        )
        defer { sqlite3_progress_handler(db, 0, nil, nil) }
        try Task.checkCancellation()
        return try body()
    }

    private func searchFrameIDs(
        query: String,
        matchQuery: String?,
        includesSubstringFallback: Bool,
        literalTokens: [String],
        asciiMatchQuery: String?,
        limit: Int32,
        sinceEpoch: TimeInterval?
    ) throws -> [UUID] {
        let timestampPredicate = sinceEpoch == nil ? "" : " AND frame_text.timestamp >= ?"
        var sources: [String] = []
        if matchQuery != nil {
            sources.append(
                """
                SELECT frame_text.frame_id, frame_text.timestamp
                FROM frame_text_fts
                JOIN frame_text ON frame_text.frame_id = frame_text_fts.frame_id
                WHERE frame_text_fts MATCH ?\(timestampPredicate)
                """
            )
        }
        if includesSubstringFallback {
            #if DEBUG
            substringSearchCount += 1
            #endif
            let literalPredicates: String
            if literalTokens.isEmpty {
                // Preserve the established punctuation-only literal search.
                literalPredicates = "instr(lower(text), lower(?)) > 0"
            } else {
                // Each Unicode token can independently use a substring or an
                // accent-folded FTS prefix; ASCII tokens remain FTS-only.
                literalPredicates = Array(
                    repeating: "(unicode_contains(text, ?) OR frame_id IN (SELECT frame_id FROM frame_text_fts WHERE frame_text_fts MATCH ?))",
                    count: literalTokens.count
                )
                    .joined(separator: " AND ")
            }
            let asciiPredicate = asciiMatchQuery == nil
                ? ""
                : " AND frame_id IN (SELECT frame_id FROM frame_text_fts WHERE frame_text_fts MATCH ?)"
            sources.append(
                """
                SELECT frame_text.frame_id, frame_text.timestamp
                FROM frame_text
                WHERE \(literalPredicates)\(asciiPredicate)\(timestampPredicate)
                """
            )
        }
        let sql = "SELECT frame_id FROM (\(sources.joined(separator: " UNION "))) ORDER BY timestamp DESC LIMIT ?;"
        return try withPreparedStatement(sql) { statement in
            var bindIndex: Int32 = 1
            if let matchQuery {
                guard bindText(matchQuery, to: statement, index: bindIndex) else {
                    throw sqliteError(message: "Text search query failed to bind")
                }
                bindIndex += 1
                if let sinceEpoch {
                    guard bindDouble(sinceEpoch, to: statement, index: bindIndex) else {
                        throw sqliteError(message: "Text search query failed to bind")
                    }
                    bindIndex += 1
                }
            }
            if includesSubstringFallback {
                if literalTokens.isEmpty {
                    guard bindText(query, to: statement, index: bindIndex) else {
                        throw sqliteError(message: "Text search query failed to bind")
                    }
                    bindIndex += 1
                } else {
                    for token in literalTokens {
                        guard let tokenMatchQuery = ftsQuery(from: token),
                              bindText(token, to: statement, index: bindIndex),
                              bindText(tokenMatchQuery, to: statement, index: bindIndex + 1) else {
                            throw sqliteError(message: "Text search query failed to bind")
                        }
                        bindIndex += 2
                    }
                }
                if let asciiMatchQuery {
                    guard bindText(asciiMatchQuery, to: statement, index: bindIndex) else {
                        throw sqliteError(message: "Text search query failed to bind")
                    }
                    bindIndex += 1
                }
                if let sinceEpoch {
                    guard bindDouble(sinceEpoch, to: statement, index: bindIndex) else {
                        throw sqliteError(message: "Text search query failed to bind")
                    }
                    bindIndex += 1
                }
            }
            guard bindInt32(limit, to: statement, index: bindIndex) else {
                throw sqliteError(message: "Text search query failed to bind")
            }
            return try readFrameIDs(from: statement, errorMessage: "Text search query failed")
        }
    }

    private func readFrameIDs(from statement: OpaquePointer, errorMessage: String) throws -> [UUID] {
        var ids: [UUID] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_ROW {
                guard let cText = sqlite3_column_text(statement, 0) else { continue }
                if let id = UUID(uuidString: String(cString: cText)) {
                    ids.append(id)
                }
                continue
            }
            guard stepResult == SQLITE_DONE else { throw sqliteError(message: errorMessage) }
            return ids
        }
    }

    private func ftsQuery(
        from query: String,
        including predicate: (String) -> Bool = { _ in true }
    ) -> String? {
        let tokens = SearchQueryTokeniser.tokens(from: query).filter(predicate)
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
        let code = sqlite3_extended_errcode(db)
        if let cText = sqlite3_errmsg(db) {
            return .sqlite("\(message) (\(String(cString: cText)))", code: code)
        }
        return .sqlite(message, code: code)
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
