//
//  ThumbnailGenerator.swift
//  JustNow
//

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ImageEncoder {
    static let thumbnailMaxSize: CGFloat = 200
    static let thumbnailQuality: CGFloat = 0.7
    static let fullImageQuality: CGFloat = 0.85
    static let lowPowerThumbnailQuality: CGFloat = 0.6
    static let lowPowerFullImageQuality: CGFloat = 0.7

    /// Generate a thumbnail from a CGImage
    static func generateThumbnail(from cgImage: CGImage) -> CGImage? {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let scale = thumbnailMaxSize / max(width, height)

        let newWidth = Int(width * scale)
        let newHeight = Int(height * scale)

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

    /// Decode JPEG data to CGImage
    static func cgImage(from jpegData: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
