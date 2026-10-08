import AppKit
import XCTest
@testable import JustNow

final class TextRecognitionManagerTests: XCTestCase {
    @MainActor
    func testSearchLayoutRecognisesTheSameSmallTextAsTheIndex() async throws {
        let image: CGImage
        do {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: 2560, height: 1440, bitsPerComponent: 8,
                bytesPerRow: 2560 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 2560, height: 1440))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            defer { NSGraphicsContext.restoreGraphicsState() }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 28), .foregroundColor: NSColor.black
            ]
            for row in 0..<17 {
                let word = row == 8 ? "yjsoon" : "epsilon"
                let text = "alpha beta gamma \(word) delta synthetic navigation capture visual layout frame \(row)"
                (text as NSString).draw(
                    at: NSPoint(x: 80, y: 1440 - 100 - row * 74), withAttributes: attributes
                )
            }
            image = try XCTUnwrap(context.makeImage())
        }

        let indexedText = await TextRecognitionManager.extractText(from: image, mode: .searchIndex)
        XCTAssertTrue(indexedText.contains("yjsoon"), "The fixture must produce a genuine search hit")
        let extractedLayout = await TextRecognitionManager.extractSearchLayout(from: image)
        let layout = try XCTUnwrap(extractedLayout)
        XCTAssertEqual(layout.highlightRects(matching: "yjsoon").count, 1)
    }

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

    func testNormaliseClipboardTextPreservesSubtractionAcrossWrappedLines() {
        let input = "result = alpha -\nbeta"

        XCTAssertEqual(
            TextRecognitionManager.normaliseClipboardText(input),
            "result = alpha - beta",
            "A standalone subtraction operator is not a word-wrap hyphen"
        )
    }

    func testNormaliseClipboardTextDoesNotDehyphenateAcrossParagraphBreak() {
        let input = "word-\n\nNext paragraph"

        XCTAssertEqual(
            TextRecognitionManager.normaliseClipboardText(input),
            "word-\nNext paragraph",
            "Keep the hyphen and a paragraph boundary, using the normaliser's single-newline convention"
        )
    }

    func testNormaliseClipboardTextRequiresLettersOnBothSidesOfWrapHyphen() {
        XCTAssertEqual(TextRecognitionManager.normaliseClipboardText("123-\nword"), "123- word")
        XCTAssertEqual(TextRecognitionManager.normaliseClipboardText("word-\n123"), "word- 123")
        XCTAssertEqual(TextRecognitionManager.normaliseClipboardText("-\nword"), "- word")
        XCTAssertEqual(TextRecognitionManager.normaliseClipboardText("word-\n \t\nNext"), "word-\nNext")
    }

    func testNormaliseClipboardTextHandlesEmptyAndWhitespaceInput() {
        XCTAssertEqual(TextRecognitionManager.normaliseClipboardText(""), "")
        XCTAssertEqual(TextRecognitionManager.normaliseClipboardText("   "), "")
        XCTAssertEqual(TextRecognitionManager.normaliseClipboardText("\t\t"), "")
        XCTAssertEqual(TextRecognitionManager.normaliseClipboardText(" \n\t\r\n \r "), "")
    }
}
