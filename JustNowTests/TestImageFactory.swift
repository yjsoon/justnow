import CoreGraphics
import Foundation
import XCTest

/// Shared CGImage builders for tests that need deterministic pixel content.
nonisolated enum TestImageFactory {
    /// RGBA8888 image whose pixels come from the supplied closure.
    static func makeImage(
        width: Int,
        height: Int,
        pixel: (Int, Int) -> (red: UInt8, green: UInt8, blue: UInt8)
    ) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let (red, green, blue) = pixel(x, y)
                bytes[offset] = red
                bytes[offset + 1] = green
                bytes[offset + 2] = blue
                bytes[offset + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    static func makeSolidImage(width: Int, height: Int, level: UInt8) -> CGImage? {
        makeImage(width: width, height: height) { _, _ in (level, level, level) }
    }
}
