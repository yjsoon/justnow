//
//  PerceptualHash.swift
//  JustNow
//

import CoreGraphics
import CoreImage

nonisolated struct PerceptualHash {
    /// Compute a 64-bit perceptual hash from a CGImage
    /// Uses average hash algorithm: resize to 8x8, convert to grayscale, threshold by mean
    /// Runs on background thread to keep main actor responsive
    @concurrent
    static func compute(from cgImage: CGImage) async -> UInt64 {
        // Create an 8x8 grayscale bitmap context
        let width = 8
        let height = 8
        var pixelData = [UInt8](repeating: 0, count: width * height)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return 0
        }

        // Draw the image scaled to 8x8
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Calculate mean
        let sum = pixelData.reduce(0) { $0 + Int($1) }
        let mean = UInt8(sum / (width * height))

        // Build hash: 1 if pixel > mean, else 0
        var hash: UInt64 = 0
        for (index, pixel) in pixelData.enumerated() {
            if pixel > mean {
                hash |= (1 << index)
            }
        }

        return hash
    }

    /// Calculate Hamming distance between two hashes
    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        let xor = a ^ b
        return xor.nonzeroBitCount
    }
}
