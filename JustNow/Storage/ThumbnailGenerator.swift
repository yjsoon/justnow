//
//  ThumbnailGenerator.swift
//  JustNow
//

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ImageEncoder {
    static let thumbnailMaxSize: CGFloat = 200
    static let thumbnailQuality: CGFloat = 0.7
    static let fullImageQuality: CGFloat = 0.85
    static let lowPowerFullImageQuality: CGFloat = 0.7

    /// Generate a thumbnail from a CGImage
    static func generateThumbnail(from cgImage: CGImage) -> CGImage? {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width > 0, height > 0 else { return nil }
        // Never upscale: a source already smaller than the thumbnail cap
        // should be stored as-is rather than inflated to 200pt.
        let scale = min(1, thumbnailMaxSize / max(width, height))

        // Extreme aspect ratios must not truncate a dimension to 0,
        // which would make CGContext creation fail.
        let newWidth = max(1, Int(width * scale))
        let newHeight = max(1, Int(height * scale))

        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage()
    }

    /// Encode CGImage as JPEG data
    static func jpegData(from cgImage: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Decode an image file, optionally downscaling during decode for OCR workloads.
    static func cgImage(from url: URL, maxPixelSize: Int? = nil) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        if let maxPixelSize, maxPixelSize > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }

        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }

    /// Decode JPEG data to CGImage
    static func cgImage(from jpegData: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
