import CoreGraphics
import XCTest
@testable import JustNow

final class TextGrabGeometryTests: XCTestCase {
    // MARK: - displayedImageRect

    func testDisplayedImageRectCentersImageInsideLetterboxedContainer() throws {
        let displayedImageRect = try XCTUnwrap(
            TextGrabGeometry.displayedImageRect(
                for: CGSize(width: 800, height: 400),
                fittedWithin: CGSize(width: 400, height: 400)
            )
        )

        XCTAssertEqual(displayedImageRect, CGRect(x: 0, y: 100, width: 400, height: 200))
    }

    func testDisplayedImageRectRejectsDegenerateSizes() {
        XCTAssertNil(
            TextGrabGeometry.displayedImageRect(
                for: .zero,
                fittedWithin: CGSize(width: 100, height: 100)
            )
        )
        XCTAssertNil(
            TextGrabGeometry.displayedImageRect(
                for: CGSize(width: 100, height: 100),
                fittedWithin: CGSize(width: 100, height: 0)
            )
        )
        XCTAssertNil(
            TextGrabGeometry.displayedImageRect(
                for: CGSize(width: -100, height: 100),
                fittedWithin: CGSize(width: 100, height: 100)
            )
        )
    }

    // MARK: - selectionRect

    func testSelectionRectClampsToDisplayedBounds() {
        let selectionRect = TextGrabGeometry.selectionRect(
            from: CGPoint(x: -20, y: 40),
            to: CGPoint(x: 120, y: 130),
            within: CGRect(x: 0, y: 0, width: 100, height: 100)
        )

        XCTAssertEqual(selectionRect, CGRect(x: 0, y: 40, width: 100, height: 60))
    }

    func testSelectionRectFromDragEntirelyOutsideBoundsCollapsesAtEdge() {
        let selectionRect = TextGrabGeometry.selectionRect(
            from: CGPoint(x: -50, y: -50),
            to: CGPoint(x: -10, y: -10),
            within: CGRect(x: 0, y: 0, width: 100, height: 100)
        )

        XCTAssertEqual(selectionRect, CGRect(x: 0, y: 0, width: 0, height: 0))
    }

    func testSelectionRectNormalisesReversedDragDirection() {
        let selectionRect = TextGrabGeometry.selectionRect(
            from: CGPoint(x: 80, y: 90),
            to: CGPoint(x: 20, y: 30),
            within: CGRect(x: 0, y: 0, width: 100, height: 100)
        )

        XCTAssertEqual(selectionRect, CGRect(x: 20, y: 30, width: 60, height: 60))
    }

    // MARK: - cropRect

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

    func testCropRectRejectsSelectionsOutsideTheDisplayedImage() {
        XCTAssertNil(
            TextGrabGeometry.cropRect(
                for: CGRect(x: 500, y: 500, width: 40, height: 40),
                displayedImageRect: CGRect(x: 0, y: 0, width: 200, height: 100),
                imageSize: CGSize(width: 400, height: 200)
            )
        )
    }

    func testCropRectRejectsDegenerateInputs() {
        XCTAssertNil(
            TextGrabGeometry.cropRect(
                for: .zero,
                displayedImageRect: CGRect(x: 0, y: 0, width: 200, height: 100),
                imageSize: CGSize(width: 400, height: 200)
            )
        )
        XCTAssertNil(
            TextGrabGeometry.cropRect(
                for: CGRect(x: 10, y: 10, width: 40, height: 40),
                displayedImageRect: CGRect(x: 0, y: 0, width: 200, height: 100),
                imageSize: .zero
            )
        )
        XCTAssertNil(
            TextGrabGeometry.cropRect(
                for: CGRect(x: 10, y: 10, width: 40, height: 40),
                displayedImageRect: .zero,
                imageSize: CGSize(width: 400, height: 200)
            )
        )
    }

    func testCropRectNeverEscapesImageBounds() throws {
        // Selection hugging the displayed image's corner with generous padding.
        let cropRect = try XCTUnwrap(
            TextGrabGeometry.cropRect(
                for: CGRect(x: 0, y: 0, width: 30, height: 30),
                displayedImageRect: CGRect(x: 0, y: 0, width: 200, height: 100),
                imageSize: CGSize(width: 400, height: 200),
                paddingFraction: 0.5,
                minimumPadding: 20
            )
        )

        XCTAssertTrue(CGRect(origin: .zero, size: CGSize(width: 400, height: 200)).contains(cropRect))
    }

    // MARK: - displayedRect

    func testDisplayedRectFlipsNormalisedVisionCoordinatesIntoOverlaySpace() {
        let displayedRect = TextGrabGeometry.displayedRect(
            forNormalisedImageRect: CGRect(x: 0.25, y: 0.5, width: 0.25, height: 0.25),
            displayedImageRect: CGRect(x: 10, y: 20, width: 100, height: 200)
        )

        XCTAssertEqual(displayedRect, CGRect(x: 35, y: 70, width: 25, height: 50))
    }

    /// Regression: Vision can emit boxes that poke outside the unit square.
    /// Each edge must be clamped independently so the box is trimmed to the
    /// visible portion rather than shifted into the displayed image.
    func testDisplayedRectClampsBoxesThatOverflowTheUnitSquare() {
        let displayed = CGRect(x: 0, y: 0, width: 100, height: 100)

        let overflowing = TextGrabGeometry.displayedRect(
            forNormalisedImageRect: CGRect(x: 0.8, y: 0.8, width: 0.5, height: 0.5),
            displayedImageRect: displayed
        )

        // Component-wise with tolerance: 1 - 0.8 is not exact in binary
        // floating point, so the clamped width is 19.999… rather than 20.
        XCTAssertEqual(overflowing.minX, 80, accuracy: 0.000_1)
        XCTAssertEqual(overflowing.minY, 0, accuracy: 0.000_1)
        XCTAssertEqual(overflowing.width, 20, accuracy: 0.000_1)
        XCTAssertEqual(overflowing.height, 20, accuracy: 0.000_1)
        XCTAssertTrue(displayed.contains(overflowing))

        let negativeOrigin = TextGrabGeometry.displayedRect(
            forNormalisedImageRect: CGRect(x: -0.25, y: -0.25, width: 0.5, height: 0.5),
            displayedImageRect: displayed
        )

        // Trimmed to the visible quarter, not shifted: only [0, 0.25] of the
        // box overlaps the unit square. 0.25 is exact in binary floating
        // point, so exact equality holds.
        XCTAssertEqual(negativeOrigin, CGRect(x: 0, y: 75, width: 25, height: 25))
        XCTAssertTrue(displayed.contains(negativeOrigin))

        let fullyOutside = TextGrabGeometry.displayedRect(
            forNormalisedImageRect: CGRect(x: 1.2, y: 1.2, width: 0.3, height: 0.3),
            displayedImageRect: displayed
        )

        XCTAssertEqual(fullyOutside.width, 0)
        XCTAssertEqual(fullyOutside.height, 0)
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
