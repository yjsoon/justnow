import CoreGraphics
import Foundation
import XCTest
@testable import JustNow

final class TextCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testSetAndHasCachedText() async {
        let cache = TextCache(directory: directory)
        let frameID = UUID()

        var hasText = await cache.hasCachedText(for: frameID)
        XCTAssertFalse(hasText)

        await cache.setText("hello world", for: frameID)

        hasText = await cache.hasCachedText(for: frameID)
        XCTAssertTrue(hasText)
        let count = await cache.count
        XCTAssertEqual(count, 1)
    }

    func testSearchMatchesTokenPrefixes() async {
        let cache = TextCache(directory: directory)
        let frameID = UUID()
        await cache.setText("Kubernetes deployment failed", for: frameID)

        let hits = await cache.searchFrameIDs(matching: "kuber", limit: 10)

        XCTAssertEqual(hits, [frameID])
    }

    func testSearchRequiresAllQueryTokens() async {
        let cache = TextCache(directory: directory)
        let frameID = UUID()
        await cache.setText("alpha bravo", for: frameID)

        let allTokensHit = await cache.searchFrameIDs(matching: "alpha bravo", limit: 10)
        let missingTokenMiss = await cache.searchFrameIDs(matching: "alpha zulu", limit: 10)

        XCTAssertEqual(allTokensHit, [frameID])
        XCTAssertTrue(missingTokenMiss.isEmpty)
    }

    /// Overwriting a frame's text must replace its FTS entry, not stack a
    /// stale one alongside it — otherwise search keeps matching text the
    /// frame no longer shows.
    func testOverwritingTextReplacesSearchIndexEntry() async {
        let cache = TextCache(directory: directory)
        let frameID = UUID()

        await cache.setText("original secret", for: frameID)
        await cache.setText("replacement contents", for: frameID)

        let staleHits = await cache.searchFrameIDs(matching: "original", limit: 10)
        let freshHits = await cache.searchFrameIDs(matching: "replacement", limit: 10)
        XCTAssertTrue(staleHits.isEmpty)
        XCTAssertEqual(freshHits, [frameID])
        let count = await cache.count
        XCTAssertEqual(count, 1)
    }

    func testSearchOrdersByRecencyAndHonoursLimit() async {
        let cache = TextCache(directory: directory)
        let oldest = UUID()
        let middle = UUID()
        let newest = UUID()
        await cache.setText("meeting notes", for: oldest, timestamp: Date(timeIntervalSince1970: 100))
        await cache.setText("meeting notes", for: middle, timestamp: Date(timeIntervalSince1970: 200))
        await cache.setText("meeting notes", for: newest, timestamp: Date(timeIntervalSince1970: 300))

        let hits = await cache.searchFrameIDs(matching: "meeting", limit: 2)

        XCTAssertEqual(hits, [newest, middle])
    }

    func testSearchSinceFilterExcludesOlderFrames() async {
        let cache = TextCache(directory: directory)
        let old = UUID()
        let recent = UUID()
        await cache.setText("status report", for: old, timestamp: Date(timeIntervalSince1970: 100))
        await cache.setText("status report", for: recent, timestamp: Date(timeIntervalSince1970: 500))

        let hits = await cache.searchFrameIDs(
            matching: "status",
            limit: 10,
            since: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(hits, [recent])
    }

    func testSearchWithNonPositiveLimitReturnsNothing() async {
        let cache = TextCache(directory: directory)
        await cache.setText("anything", for: UUID())

        let zeroLimit = await cache.searchFrameIDs(matching: "anything", limit: 0)
        let negativeLimit = await cache.searchFrameIDs(matching: "anything", limit: -3)

        XCTAssertTrue(zeroLimit.isEmpty)
        XCTAssertTrue(negativeLimit.isEmpty)
    }

    /// Queries are user-controlled input that reaches SQL; quoting and
    /// injection-shaped strings must neither throw, corrupt the store, nor
    /// match unrelated frames.
    func testHostileQueriesAreHarmless() async {
        let cache = TextCache(directory: directory)
        let frameID = UUID()
        await cache.setText("ordinary contents", for: frameID)

        let injection = await cache.searchFrameIDs(
            matching: "'; DROP TABLE frame_text;--",
            limit: 10
        )
        let quotes = await cache.searchFrameIDs(matching: "\"quoted\" phrase\"", limit: 10)
        XCTAssertTrue(injection.isEmpty)
        XCTAssertTrue(quotes.isEmpty)

        // The table must still exist and be writable/searchable afterwards.
        await cache.setText("still alive", for: UUID())
        let hits = await cache.searchFrameIDs(matching: "ordinary", limit: 10)
        XCTAssertEqual(hits, [frameID])
        let count = await cache.count
        XCTAssertEqual(count, 2)
    }

    func testPunctuationOnlyQueryFallsBackToSubstringMatch() async {
        let cache = TextCache(directory: directory)
        let frameID = UUID()
        await cache.setText("Loading...", for: frameID)

        let hits = await cache.searchFrameIDs(matching: "...", limit: 10)

        XCTAssertEqual(hits, [frameID])
    }

    func testDiacriticInsensitiveSearch() async {
        let cache = TextCache(directory: directory)
        let frameID = UUID()
        await cache.setText("café menu", for: frameID)

        let hits = await cache.searchFrameIDs(matching: "cafe", limit: 10)

        XCTAssertEqual(hits, [frameID])
    }

    func testPruneKeepsOnlyValidFrameIDs() async {
        let cache = TextCache(directory: directory)
        let keep = UUID()
        let drop = UUID()
        await cache.setText("keep me", for: keep)
        await cache.setText("drop me", for: drop)

        await cache.prune(keepingFrameIDs: [keep])

        let keptHasText = await cache.hasCachedText(for: keep)
        let droppedHasText = await cache.hasCachedText(for: drop)
        XCTAssertTrue(keptHasText)
        XCTAssertFalse(droppedHasText)
        let staleHits = await cache.searchFrameIDs(matching: "drop", limit: 10)
        XCTAssertTrue(staleHits.isEmpty)
    }

    func testClearEmptiesTextSearchAndLayouts() async {
        let cache = TextCache(directory: directory)
        let frameID = UUID()
        await cache.setText("something", for: frameID)
        await cache.setSearchLayout(makeLayout(), for: frameID)

        await cache.clear()

        let count = await cache.count
        XCTAssertEqual(count, 0)
        let hits = await cache.searchFrameIDs(matching: "something", limit: 10)
        XCTAssertTrue(hits.isEmpty)
        let layout = await cache.getSearchLayout(for: frameID)
        XCTAssertNil(layout)
    }

    func testSearchLayoutRoundTrip() async {
        let cache = TextCache(directory: directory)
        let frameID = UUID()
        let layout = makeLayout()

        await cache.setSearchLayout(layout, for: frameID)

        let restored = await cache.getSearchLayout(for: frameID)
        XCTAssertEqual(restored?.lines.count, 1)
        XCTAssertEqual(restored?.lines.first?.text, "Menu bar")
        XCTAssertEqual(restored?.lines.first?.words.map(\.text), ["Menu", "bar"])
        XCTAssertEqual(
            restored?.lines.first?.rect,
            CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.1)
        )
    }

    func testTextPersistsAcrossReopen() async {
        let frameID = UUID()
        do {
            let cache = TextCache(directory: directory)
            await cache.setText("persisted contents", for: frameID)
        }

        let reopened = TextCache(directory: directory)
        let hits = await reopened.searchFrameIDs(matching: "persisted", limit: 10)

        XCTAssertEqual(hits, [frameID])
    }

    private func makeLayout() -> SearchTextLayout {
        SearchTextLayout(
            lines: [
                SearchTextLine(
                    text: "Menu bar",
                    rect: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.1),
                    words: [
                        SearchTextWord(text: "Menu", rect: CGRect(x: 0.1, y: 0.5, width: 0.14, height: 0.1)),
                        SearchTextWord(text: "bar", rect: CGRect(x: 0.26, y: 0.5, width: 0.1, height: 0.1))
                    ]
                )
            ]
        )
    }
}
