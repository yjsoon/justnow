//
//  ImageUtils.swift
//  JustNow
//

import AppKit
import CoreImage
import CoreVideo

/// Convert CGImage to NSImage
func imageFromCGImage(_ cgImage: CGImage) -> NSImage {
    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
}

/// Fast thumbnail generation from CGImage
func thumbnailFromCGImage(_ cgImage: CGImage, maxSize: CGFloat) -> NSImage {
    let originalWidth = CGFloat(cgImage.width)
    let originalHeight = CGFloat(cgImage.height)
    let scale = maxSize / max(originalWidth, originalHeight)

    let newWidth = Int(originalWidth * scale)
    let newHeight = Int(originalHeight * scale)

    guard let context = CGContext(
        data: nil,
        width: newWidth,
        height: newHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    context.interpolationQuality = .medium
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))

    guard let scaledImage = context.makeImage() else {
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    return NSImage(cgImage: scaledImage, size: NSSize(width: newWidth, height: newHeight))
}

extension Collection {
    /// Safe subscript that returns nil for out-of-bounds indices
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
