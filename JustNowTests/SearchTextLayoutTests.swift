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

    /// Multi-token queries use union semantics per word: a word matching any
    /// query token is highlighted, even when other tokens miss entirely.
    func testMultiTokenQueryHighlightsWordsMatchingAnyToken() {
        let layout = makeLayout()

        XCTAssertEqual(layout.highlightRects(matching: "menu zzz"), [menuRect])
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
