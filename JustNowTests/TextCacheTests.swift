import XCTest
@testable import JustNow

final class TextCacheTests: XCTestCase {

    private var tempDir: URL!
    private var cache: TextCache!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("JustNowTests-TextCache-\(UUID().uuidString)")
        cache = TextCache(directory: tempDir)
    }

    override func tearDown() async throws {
        cache = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    // MARK: - Basic CRUD

    func testSetAndGetTextRoundTrip() async {
        let id = UUID()
        await cache.setText("Hello world", for: id)
        let text = await cache.getText(for: id)
        XCTAssertEqual(text, "Hello world")
    }

    func testGetTextForNonexistentFrameReturnsNil() async {
        let text = await cache.getText(for: UUID())
        XCTAssertNil(text)
    }

    func testHasCachedTextReturnsTrueWhenPresent() async {
        let id = UUID()
        await cache.setText("test", for: id)
        let has = await cache.hasCachedText(for: id)
        XCTAssertTrue(has)
    }

    func testHasCachedTextReturnsFalseWhenAbsent() async {
        let has = await cache.hasCachedText(for: UUID())
        XCTAssertFalse(has)
    }

    func testSetTextOverwritesExistingEntry() async {
        let id = UUID()
        await cache.setText("original", for: id)
        await cache.setText("updated", for: id)
        let text = await cache.getText(for: id)
        XCTAssertEqual(text, "updated")
    }

    func testCountReflectsInsertions() async {
        XCTAssertEqual(await cache.count, 0)
        await cache.setText("a", for: UUID())
        await cache.setText("b", for: UUID())
        XCTAssertEqual(await cache.count, 2)
    }

    // MARK: - Removal

    func testRemoveTextDeletesEntry() async {
        let id = UUID()
        await cache.setText("gone", for: id)
        await cache.removeText(for: id)
        let text = await cache.getText(for: id)
        XCTAssertNil(text)
    }

    func testRemoveTextForNonexistentFrameDoesNotCrash() async {
        await cache.removeText(for: UUID())
        // No assertion needed — just verifying no crash
    }

    // MARK: - Clear

    func testClearRemovesAllEntries() async {
        await cache.setText("a", for: UUID())
        await cache.setText("b", for: UUID())
        await cache.clear()
        XCTAssertEqual(await cache.count, 0)
    }

    // MARK: - cachedFrameIDs

    func testCachedFrameIDsReturnsSubsetThatExists() async {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        await cache.setText("a", for: id1)
        await cache.setText("b", for: id2)

        let cached = await cache.cachedFrameIDs(in: [id1, id2, id3])
        XCTAssertEqual(cached, [id1, id2])
    }

    func testCachedFrameIDsWithEmptyInputReturnsEmpty() async {
        let cached = await cache.cachedFrameIDs(in: [])
        XCTAssertTrue(cached.isEmpty)
    }

    // MARK: - Prune

    func testPruneRemovesEntriesNotInKeepSet() async {
        let keep = UUID()
        let discard = UUID()
        await cache.setText("keep", for: keep)
        await cache.setText("discard", for: discard)

        await cache.prune(keepingFrameIDs: [keep])

        XCTAssertNotNil(await cache.getText(for: keep))
        XCTAssertNil(await cache.getText(for: discard))
    }

    // MARK: - FTS Search

    func testSearchFindsMatchingText() async {
        let id = UUID()
        await cache.setText("The quick brown fox jumps over the lazy dog", for: id)

        let results = await cache.searchFrameIDs(matching: "brown fox", limit: 10)
        XCTAssertTrue(results.contains(id), "FTS search should find frame with matching text")
    }

    func testSearchReturnsEmptyForNoMatch() async {
        let id = UUID()
        await cache.setText("Hello world", for: id)

        let results = await cache.searchFrameIDs(matching: "xyznotfound", limit: 10)
        XCTAssertTrue(results.isEmpty)
    }

    func testSearchRespectsLimit() async {
        for i in 0..<5 {
            await cache.setText("common keyword item \(i)", for: UUID())
        }

        let results = await cache.searchFrameIDs(matching: "common keyword", limit: 2)
        XCTAssertLessThanOrEqual(results.count, 2)
    }

    func testSearchWithZeroLimitReturnsEmpty() async {
        await cache.setText("test", for: UUID())
        let results = await cache.searchFrameIDs(matching: "test", limit: 0)
        XCTAssertTrue(results.isEmpty)
    }

    func testSearchWithSinceDateFiltersOldEntries() async {
        let oldID = UUID()
        let newID = UUID()

        let oldTimestamp = Date(timeIntervalSince1970: 1000)
        let newTimestamp = Date(timeIntervalSince1970: 2000)
        let cutoff = Date(timeIntervalSince1970: 1500)

        await cache.setText("searchable text here", for: oldID, timestamp: oldTimestamp)
        await cache.setText("searchable text here", for: newID, timestamp: newTimestamp)

        let results = await cache.searchFrameIDs(matching: "searchable", limit: 10, since: cutoff)
        XCTAssertTrue(results.contains(newID), "New entry should match")
        XCTAssertFalse(results.contains(oldID), "Old entry should be filtered by since date")
    }

    // MARK: - Fallback substring search

    func testFallbackSearchWorksForSpecialCharacters() async {
        let id = UUID()
        // FTS tokenizer strips special characters, so this tests the INSTR fallback
        await cache.setText("error: file_not_found (code 404)", for: id)

        let results = await cache.searchFrameIDs(matching: "404", limit: 10)
        XCTAssertTrue(results.contains(id), "Fallback search should find numeric substring")
    }

    // MARK: - Unicode

    func testSearchWorksWithUnicodeText() async {
        let id = UUID()
        await cache.setText("日本語テキスト検索テスト", for: id)

        let results = await cache.searchFrameIDs(matching: "検索", limit: 10)
        // FTS5 unicode61 tokenizer should handle CJK
        XCTAssertFalse(results.isEmpty, "Search should handle unicode text")
    }
}
