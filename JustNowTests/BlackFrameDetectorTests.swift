import CoreGraphics
import XCTest
@testable import JustNow

final class BlackFrameDetectorTests: XCTestCase {
    func testDetectsUniformBlackFrame() throws {
        let detector = BlackFrameDetector.screenOff
        let image = try makeImage(width: 16, height: 16) { _, _ in
            (0, 0, 0, 255)
        }

        XCTAssertTrue(detector.isBlackFrame(image))
    }

    func testRejectsUniformDarkGreyFrame() throws {
        let detector = BlackFrameDetector.screenOff
        let image = try makeImage(width: 16, height: 16) { _, _ in
            (12, 12, 12, 255)
        }

        XCTAssertFalse(detector.isBlackFrame(image))
    }

    func testRejectsStructuredDarkFrame() throws {
        let detector = BlackFrameDetector.screenOff
        let image = try makeImage(width: 16, height: 16) { x, y in
            if (4..<12).contains(x) && (4..<12).contains(y) {
                return (20, 20, 20, 255)
            }
            return (0, 0, 0, 255)
        }

        XCTAssertFalse(detector.isBlackFrame(image))
    }

    private func makeImage(
        width: Int,
        height: Int,
        pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let (red, green, blue, alpha) = pixel(x, y)
                bytes[offset] = red
                bytes[offset + 1] = green
                bytes[offset + 2] = blue
                bytes[offset + 3] = alpha
            }
        }

        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)

        return try XCTUnwrap(
            CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )
    }
}
