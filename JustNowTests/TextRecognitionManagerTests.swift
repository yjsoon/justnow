import CoreGraphics
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

    func testDisplayedImageRectCentersImageInsideLetterboxedContainer() throws {
        let displayedImageRect = try XCTUnwrap(
            TextGrabGeometry.displayedImageRect(
                for: CGSize(width: 800, height: 400),
                fittedWithin: CGSize(width: 400, height: 400)
            )
        )

        XCTAssertEqual(displayedImageRect, CGRect(x: 0, y: 100, width: 400, height: 200))
    }

    func testCropRectMapsOverlaySelectionIntoImageCoordinates() throws {
        let selectionRect = CGRect(x: 50, y: 20, width: 100, height: 80)
        let cropRect = try XCTUnwrap(
            TextGrabGeometry.cropRect(
                for: selectionRect,
                displayedImageRect: CGRect(x: 0, y: 0, width: 200, height: 100),
                imageSize: CGSize(width: 400, height: 200),
                paddingFraction: 0,
                minimumPadding: 0
            )
        )

        XCTAssertEqual(cropRect, CGRect(x: 100, y: 40, width: 200, height: 160))
    }

    func testCropRectAccountsForDisplayedImageInset() throws {
        let selectionRect = CGRect(x: 100, y: 140, width: 200, height: 100)
        let cropRect = try XCTUnwrap(
            TextGrabGeometry.cropRect(
                for: selectionRect,
                displayedImageRect: CGRect(x: 0, y: 100, width: 400, height: 200),
                imageSize: CGSize(width: 800, height: 400),
                paddingFraction: 0,
                minimumPadding: 0
            )
        )

        XCTAssertEqual(cropRect, CGRect(x: 200, y: 80, width: 400, height: 200))
    }

    func testCropRectDefaultPaddingStaysTightForSmallSelections() throws {
        let selectionRect = CGRect(x: 10, y: 10, width: 40, height: 24)
        let cropRect = try XCTUnwrap(
            TextGrabGeometry.cropRect(
                for: selectionRect,
                displayedImageRect: CGRect(x: 0, y: 0, width: 200, height: 100),
                imageSize: CGSize(width: 400, height: 200)
            )
        )

        XCTAssertEqual(cropRect, CGRect(x: 19, y: 19, width: 82, height: 50))
    }

    func testSelectionRectClampsToDisplayedBounds() {
        let selectionRect = TextGrabGeometry.selectionRect(
            from: CGPoint(x: -20, y: 40),
            to: CGPoint(x: 120, y: 130),
            within: CGRect(x: 0, y: 0, width: 100, height: 100)
        )

        XCTAssertEqual(selectionRect, CGRect(x: 0, y: 40, width: 100, height: 60))
    }

    func testHighlightRectsPreferWordBoxesForPrefixMatches() {
        let menuRect = CGRect(x: 0.12, y: 0.55, width: 0.14, height: 0.08)
        let barRect = CGRect(x: 0.28, y: 0.55, width: 0.1, height: 0.08)
        let layout = SearchTextLayout(
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

        XCTAssertEqual(layout.highlightRects(matching: "men"), [menuRect])
        XCTAssertEqual(layout.highlightRects(matching: "menu bar"), [menuRect, barRect])
    }

    func testHighlightRectsFallBackToLineRectWhenWordBoxesAreMissing() {
        let lineRect = CGRect(x: 0.18, y: 0.34, width: 0.4, height: 0.11)
        let layout = SearchTextLayout(
            lines: [
                SearchTextLine(
                    text: "Window capture paused",
                    rect: lineRect,
                    words: []
                )
            ]
        )

        XCTAssertEqual(layout.highlightRects(matching: "capture"), [lineRect])
    }

    func testDisplayedRectFlipsNormalisedVisionCoordinatesIntoOverlaySpace() {
        let displayedRect = TextGrabGeometry.displayedRect(
            forNormalisedImageRect: CGRect(x: 0.25, y: 0.5, width: 0.25, height: 0.25),
            displayedImageRect: CGRect(x: 10, y: 20, width: 100, height: 200)
        )

        XCTAssertEqual(displayedRect, CGRect(x: 35, y: 70, width: 25, height: 50))
    }

    func testPaddedDisplayedRectAddsFivePointsAndClampsToImageBounds() {
        let displayedRect = TextGrabGeometry.paddedDisplayedRect(
            forNormalisedImageRect: CGRect(x: 0.02, y: 0.9, width: 0.2, height: 0.08),
            displayedImageRect: CGRect(x: 10, y: 20, width: 100, height: 200),
            padding: 5
        )

        XCTAssertEqual(displayedRect, CGRect(x: 10, y: 20, width: 27, height: 25))
    }
}
