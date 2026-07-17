import CoreGraphics
import Foundation
import XCTest
@testable import JustNow

final class ImageEncoderTests: XCTestCase {
    /// Regression: sources already smaller than the thumbnail cap used to be
    /// upscaled to 200pt, inflating disk and cache cost for tiny frames.
    func testGenerateThumbnailDoesNotUpscaleSmallImages() throws {
        let small = try XCTUnwrap(TestImageFactory.makeSolidImage(width: 120, height: 60, level: 90))

        let thumbnail = try XCTUnwrap(ImageEncoder.generateThumbnail(from: small))

        XCTAssertEqual(thumbnail.width, 120)
        XCTAssertEqual(thumbnail.height, 60)
    }

    func testGenerateThumbnailPreservesAspectRatioWhenDownscaling() throws {
        let wide = try XCTUnwrap(TestImageFactory.makeSolidImage(width: 400, height: 200, level: 90))

        let thumbnail = try XCTUnwrap(ImageEncoder.generateThumbnail(from: wide))

        XCTAssertEqual(thumbnail.width, Int(ImageEncoder.thumbnailMaxSize))
        XCTAssertEqual(thumbnail.height, Int(ImageEncoder.thumbnailMaxSize) / 2)
    }

    func testJPEGRoundTripPreservesDimensions() throws {
        let image = try XCTUnwrap(TestImageFactory.makeSolidImage(width: 10, height: 6, level: 120))

        let data = try XCTUnwrap(ImageEncoder.jpegData(from: image, quality: 0.8))
        let decoded = try XCTUnwrap(ImageEncoder.cgImage(from: data))

        XCTAssertEqual(decoded.width, 10)
        XCTAssertEqual(decoded.height, 6)
    }

    func testDecodingGarbageDataReturnsNil() {
        XCTAssertNil(ImageEncoder.cgImage(from: Data("definitely not a JPEG".utf8)))
        XCTAssertNil(ImageEncoder.cgImage(from: Data()))
    }

    func testDecodingMissingFileReturnsNil() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageEncoderTests-missing-\(UUID().uuidString).jpg")

        XCTAssertNil(ImageEncoder.cgImage(from: missing))
        XCTAssertNil(ImageEncoder.cgImage(from: missing, maxPixelSize: 100))
    }

    func testMaxPixelSizeDecodingBoundsTheLargerDimension() throws {
        let image = try XCTUnwrap(TestImageFactory.makeSolidImage(width: 64, height: 32, level: 90))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageEncoderTests-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try XCTUnwrap(ImageEncoder.jpegData(from: image, quality: 0.8))
        try data.write(to: url)

        let decoded = try XCTUnwrap(ImageEncoder.cgImage(from: url, maxPixelSize: 16))
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 16)

        // Non-positive size means "no downscale", not a zero-size decode.
        let fullSize = try XCTUnwrap(ImageEncoder.cgImage(from: url, maxPixelSize: 0))
        XCTAssertEqual(fullSize.width, 64)
    }
}
