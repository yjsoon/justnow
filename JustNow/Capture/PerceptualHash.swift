//
//  PerceptualHash.swift
//  JustNow
//

import CoreGraphics
import CoreImage

nonisolated struct PerceptualHash {
    // Cache the colourspace across calls; per-call construction is wasteful on
    // a per-frame hot path.
    private static let grayColorSpace = CGColorSpaceCreateDeviceGray()

    /// Compute a 64-bit perceptual hash from a CGImage
    /// Uses average hash algorithm: resize to 8x8, convert to grayscale, threshold by mean
    /// Runs on background thread to keep main actor responsive
    @concurrent
    @Sendable
    static func compute(from cgImage: CGImage) async -> UInt64 {
        guard !Task.isCancelled else { return 0 }

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
            space: grayColorSpace,
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

        guard !Task.isCancelled else { return 0 }

        // Build hash: 1 if pixel >= mean, else 0. Using >= (not >) guarantees a
        // non-zero hash for every decodable image (the maximum pixel is always
        // >= the mean), which keeps 0 reserved as the "no hash" legacy sentinel
        // that dedupe and timeline filtering treat as always-keep. A uniform
        // frame hashing to 0 would otherwise bypass duplicate detection
        // entirely and store every capture of a static solid-colour screen.
        var hash: UInt64 = 0
        for (index, pixel) in pixelData.enumerated() {
            if pixel >= mean {
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
