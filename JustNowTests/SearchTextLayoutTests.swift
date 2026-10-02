import CoreGraphics
import XCTest
@testable import JustNow

final class SearchTextLayoutTests: XCTestCase {
    // MARK: - Tokeniser

    func testTokeniserLowercasesAndSplitsOnNonAlphanumerics() {
        XCTAssertEqual(
            SearchQueryTokeniser.tokens(from: "Hello, World! v2.1_beta"),
            ["hello", "world", "v2", "1", "beta"]
        )
    }

    func testTokeniserReturnsNothingForPunctuationOrWhitespaceOnlyInput() {
        XCTAssertEqual(SearchQueryTokeniser.tokens(from: ""), [])
        XCTAssertEqual(SearchQueryTokeniser.tokens(from: "   "), [])
        XCTAssertEqual(SearchQueryTokeniser.tokens(from: "... !!! ---"), [])
    }

    // MARK: - highlightRects

    func testEmptyAndWhitespaceQueriesHighlightNothing() {
        let layout = makeLayout()

        XCTAssertEqual(layout.highlightRects(matching: ""), [])
        XCTAssertEqual(layout.highlightRects(matching: "   \n"), [])
    }

    func testNoMatchReturnsEmpty() {
        let layout = makeLayout()

        XCTAssertEqual(layout.highlightRects(matching: "zebra"), [])
    }

    func testHighlightRectsPreferWordBoxesForPrefixMatches() {
        let layout = makeLayout()

        XCTAssertEqual(layout.highlightRects(matching: "men"), [menuRect])
        XCTAssertEqual(layout.highlightRects(matching: "menu bar"), [menuRect, barRect])
    }

    func testMatchingIsCaseInsensitive() {
        let layout = makeLayout()

        XCTAssertEqual(layout.highlightRects(matching: "MENU"), [menuRect])
    }

    func testDiacriticInsensitiveSearchResultsHighlightTheirMatchingWords() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchHighlightTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TextCache(directory: directory)

        // FTS removes diacritics. Exercise both directions and a prefix so a
        // returned result cannot silently lose its word-level highlights.
        for (words, query) in [
            (["Café", "résumé"], "CAFE res"),
            (["Cafe", "resume"], "café rés"),
            (["Cafe\u{301}", "re\u{301}sume\u{301}"], "cafe resume")
        ] {
            let id = UUID()
            let text = words.joined(separator: " ")
            await cache.setText(text, for: id, timestamp: Date())
            let results = try await cache.searchFrameIDs(matching: query, limit: 10)
            XCTAssertTrue(results.contains(id))

            let layout = SearchTextLayout(lines: [SearchTextLine(
                text: text,
                rect: CGRect(x: 0.1, y: 0.5, width: 0.4, height: 0.1),
                words: [
                    SearchTextWord(text: words[0], rect: menuRect),
                    SearchTextWord(text: words[1], rect: barRect)
                ]
            )])
            XCTAssertEqual(layout.highlightRects(matching: query), [menuRect, barRect])
        }
    }

    /// Multi-token queries use union semantics per word: a word matching any
    /// query token is highlighted, even when other tokens miss entirely.
    func testMultiTokenQueryHighlightsWordsMatchingAnyToken() {
        let layout = makeLayout()

        XCTAssertEqual(layout.highlightRects(matching: "menu zzz"), [menuRect])
    }

    func testASCIIPrefixHitDoesNotHideUnsegmentedSubstringHit() {
        let line = SearchTextLine(
            text: "chrome 東京都庁",
            rect: CGRect(x: 0.1, y: 0.5, width: 0.4, height: 0.1),
            words: [
                SearchTextWord(text: "chrome", rect: menuRect),
                SearchTextWord(text: "東京都庁", rect: barRect)
            ]
        )
        let layout = SearchTextLayout(lines: [line])

        XCTAssertEqual(layout.highlightRects(matching: "chrome 京都"), [menuRect, barRect])
        XCTAssertEqual(layout.highlightRects(matching: "京都"), [barRect])
        // Keep ASCII tokens as prefixes, even alongside a non-ASCII match.
        XCTAssertEqual(layout.highlightRects(matching: "rome 京都"), [barRect])
        XCTAssertEqual(layout.highlightRects(matching: "chrome 大阪"), [menuRect])
    }

    func testWordHitSuppressesLineFallbackOnlyForThatLine() {
        let wordedLine = SearchTextLine(
            text: "Menu bar",
            rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1),
            words: [SearchTextWord(text: "Menu", rect: menuRect)]
        )
        let wordlessLineRect = CGRect(x: 0.1, y: 0.4, width: 0.4, height: 0.1)
        let wordlessLine = SearchTextLine(
            text: "Menu preferences pane",
            rect: wordlessLineRect,
            words: []
        )
        let layout = SearchTextLayout(lines: [wordedLine, wordlessLine])

        XCTAssertEqual(layout.highlightRects(matching: "menu"), [menuRect, wordlessLineRect])
    }

    func testFallsBackToLineRectWhenWordBoxesAreMissing() {
        let lineRect = CGRect(x: 0.18, y: 0.34, width: 0.4, height: 0.11)
        let layout = SearchTextLayout(
            lines: [
                SearchTextLine(text: "Window capture paused", rect: lineRect, words: [])
            ]
        )

        XCTAssertEqual(layout.highlightRects(matching: "capture"), [lineRect])
    }

    func testPunctuationOnlyQueryFallsBackToSubstringMatch() {
        let lineRect = CGRect(x: 0.14, y: 0.3, width: 0.42, height: 0.1)
        let layout = SearchTextLayout(
            lines: [
                SearchTextLine(text: "Loading...", rect: lineRect, words: [])
            ]
        )

        XCTAssertEqual(layout.highlightRects(matching: "..."), [lineRect])
        XCTAssertEqual(layout.highlightRects(matching: "!!!"), [])
    }

    func testEmptyLayoutIsEmptyAndHighlightsNothing() {
        let layout = SearchTextLayout(lines: [])

        XCTAssertTrue(layout.isEmpty)
        XCTAssertEqual(layout.highlightRects(matching: "anything"), [])
    }

    // MARK: - Fixtures

    private let menuRect = CGRect(x: 0.12, y: 0.55, width: 0.14, height: 0.08)
    private let barRect = CGRect(x: 0.28, y: 0.55, width: 0.1, height: 0.08)

    private func makeLayout() -> SearchTextLayout {
        SearchTextLayout(
            lines: [
                SearchTextLine(
                    text: "Menu bar",
                    rect: CGRect(x: 0.1, y: 0.52, width: 0.32, height: 0.12),
                    words: [
                        SearchTextWord(text: "Menu", rect: menuRect),
                        SearchTextWord(text: "bar", rect: barRect)
                    ]
                )
            ]
        )
    }
}
