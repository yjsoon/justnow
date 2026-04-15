import CoreGraphics
import XCTest
@testable import JustNow

final class OverlayBackdropPerformanceTests: XCTestCase {
    func testBackdropThumbnailGenerationCapsImageSize() throws {
        let image = try XCTUnwrap(makeTestImage(width: 3840, height: 2160))
        let thumbnail = try XCTUnwrap(ImageEncoder.generateThumbnail(from: image))

        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), Int(ImageEncoder.thumbnailMaxSize))
    }

    func testBackdropThumbnailGenerationPerformance() throws {
        let image = try XCTUnwrap(makeTestImage(width: 3840, height: 2160))

        measure(metrics: [XCTClockMetric()]) {
            _ = ImageEncoder.generateThumbnail(from: image)
        }
    }

    func testBackdropFullResolutionPreparationPerformance() throws {
        let image = try XCTUnwrap(makeTestImage(width: 3840, height: 2160))

        measure(metrics: [XCTClockMetric()]) {
            guard let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                XCTFail("Failed to create context")
                return
            }

            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            XCTAssertNotNil(context.makeImage())
        }
    }

    private func makeTestImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        for row in stride(from: 0, to: height, by: 96) {
            let fraction = CGFloat(row) / CGFloat(height)
            context.setFillColor(
                CGColor(
                    red: fraction,
                    green: 0.25 + (fraction * 0.5),
                    blue: 0.95 - (fraction * 0.4),
                    alpha: 1
                )
            )
            context.fill(CGRect(x: 0, y: row, width: width, height: min(96, height - row)))
        }

        context.setFillColor(CGColor(red: 0.96, green: 0.92, blue: 0.28, alpha: 1))
        context.fill(CGRect(x: width / 8, y: height / 5, width: width / 3, height: height / 6))

        context.setFillColor(CGColor(red: 0.14, green: 0.18, blue: 0.22, alpha: 1))
        context.fill(CGRect(x: width / 2, y: height / 3, width: width / 4, height: height / 5))

        return context.makeImage()
    }
}
