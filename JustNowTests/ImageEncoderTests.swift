import CoreGraphics
import XCTest
@testable import JustNow

final class ImageEncoderTests: XCTestCase {

    // MARK: - Helpers

    private func makeTestImage(width: Int = 200, height: Int = 100) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Fill with a gradient-ish pattern so compression is nontrivial
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1.0, green: 0.3, blue: 0.1, alpha: 1.0)
        context.fill(CGRect(x: 50, y: 25, width: 100, height: 50))
        return context.makeImage()!
    }

    // MARK: - JPEG encode/decode round-trip

    func testJpegDataProducesNonNilData() {
        let image = makeTestImage()
        let data = ImageEncoder.jpegData(from: image, quality: 0.85)
        XCTAssertNotNil(data)
        XCTAssertGreaterThan(data!.count, 0)
    }

    func testJpegRoundTripPreservesDimensions() throws {
        let image = makeTestImage(width: 300, height: 150)
        let data = try XCTUnwrap(ImageEncoder.jpegData(from: image, quality: 0.9))
        let decoded = try XCTUnwrap(ImageEncoder.cgImage(from: data))

        XCTAssertEqual(decoded.width, 300)
        XCTAssertEqual(decoded.height, 150)
    }

    func testHigherQualityProducesLargerData() throws {
        let image = makeTestImage()
        let lowQ = try XCTUnwrap(ImageEncoder.jpegData(from: image, quality: 0.1))
        let highQ = try XCTUnwrap(ImageEncoder.jpegData(from: image, quality: 0.95))
        XCTAssertGreaterThan(highQ.count, lowQ.count, "Higher quality JPEG should be larger")
    }

    func testCgImageFromInvalidDataReturnsNil() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03])
        XCTAssertNil(ImageEncoder.cgImage(from: garbage))
    }

    // MARK: - Thumbnail generation

    func testThumbnailRespectsMaxSize() throws {
        let image = makeTestImage(width: 1920, height: 1080)
        let thumb = try XCTUnwrap(ImageEncoder.generateThumbnail(from: image))

        let maxDim = max(thumb.width, thumb.height)
        XCTAssertLessThanOrEqual(CGFloat(maxDim), ImageEncoder.thumbnailMaxSize,
                                  "Thumbnail should not exceed \(ImageEncoder.thumbnailMaxSize)px")
    }

    func testThumbnailPreservesAspectRatio() throws {
        let image = makeTestImage(width: 1600, height: 900)
        let thumb = try XCTUnwrap(ImageEncoder.generateThumbnail(from: image))

        let originalRatio = Double(1600) / Double(900)
        let thumbRatio = Double(thumb.width) / Double(thumb.height)
        XCTAssertEqual(thumbRatio, originalRatio, accuracy: 0.05,
                       "Thumbnail aspect ratio should match original")
    }

    func testThumbnailOfSmallImageStillWorks() throws {
        // Image smaller than thumbnailMaxSize — should still produce a valid thumbnail
        let image = makeTestImage(width: 50, height: 30)
        let thumb = try XCTUnwrap(ImageEncoder.generateThumbnail(from: image))
        XCTAssertGreaterThan(thumb.width, 0)
        XCTAssertGreaterThan(thumb.height, 0)
    }

    // MARK: - Quality constants

    func testQualityConstantsAreInValidRange() {
        let qualities = [
            ImageEncoder.thumbnailQuality,
            ImageEncoder.fullImageQuality,
            ImageEncoder.lowPowerThumbnailQuality,
            ImageEncoder.lowPowerFullImageQuality,
        ]

        for q in qualities {
            XCTAssertGreaterThan(q, 0, "Quality should be > 0")
            XCTAssertLessThanOrEqual(q, 1.0, "Quality should be <= 1.0")
        }
    }

    func testLowPowerQualitiesAreLowerThanStandard() {
        XCTAssertLessThan(ImageEncoder.lowPowerFullImageQuality, ImageEncoder.fullImageQuality)
        XCTAssertLessThan(ImageEncoder.lowPowerThumbnailQuality, ImageEncoder.thumbnailQuality)
    }
}
