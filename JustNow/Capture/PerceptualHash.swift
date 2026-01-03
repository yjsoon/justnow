//
//  PerceptualHash.swift
//  JustNow
//

import CoreVideo
import CoreImage
import Accelerate

struct PerceptualHash {
    /// Compute a 64-bit perceptual hash from a CVPixelBuffer
    /// Uses average hash algorithm: resize to 8x8, convert to grayscale, threshold by mean
    static func compute(from pixelBuffer: CVPixelBuffer) -> UInt64 {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Resize to 8x8
        let scale = 8.0 / max(ciImage.extent.width, ciImage.extent.height)
        let resized = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Create grayscale version
        let grayscale = resized.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])

        let context = CIContext(options: [.useSoftwareRenderer: false])
        var bitmap = [UInt8](repeating: 0, count: 64)

        // Render 8x8 grayscale
        let rect = CGRect(x: 0, y: 0, width: 8, height: 8)
        context.render(grayscale, toBitmap: &bitmap, rowBytes: 8, bounds: rect, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())

        // Calculate mean
        let sum = bitmap.reduce(0) { $0 + Int($1) }
        let mean = UInt8(sum / 64)

        // Build hash: 1 if pixel > mean, else 0
        var hash: UInt64 = 0
        for (index, pixel) in bitmap.enumerated() {
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
