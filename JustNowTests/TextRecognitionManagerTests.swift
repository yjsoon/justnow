import XCTest
@testable import JustNow

final class TextRecognitionManagerTests: XCTestCase {
    func testNormaliseClipboardTextCollapsesWrappedParagraphs() {
        let input = "Drag to\ncopy the text\nnow"

        XCTAssertEqual(
            TextRecognitionManager.normaliseClipboardText(input),
            "Drag to copy the text now"
        )
    }

    func testNormaliseClipboardTextPreservesBulletLists() {
        let input = """
        • First item
        • Second item
        """

        XCTAssertEqual(
            TextRecognitionManager.normaliseClipboardText(input),
            """
            • First item
            • Second item
            """
        )
    }

    func testNormaliseClipboardTextRepairsHyphenatedWraps() {
        let input = "multi-\nline capture"

        XCTAssertEqual(
            TextRecognitionManager.normaliseClipboardText(input),
            "multiline capture"
        )
    }

    func testNormaliseClipboardTextHandlesEmptyAndWhitespaceInput() {
        XCTAssertEqual(TextRecognitionManager.normaliseClipboardText(""), "")
    }
}
