//
//  ImageUtils.swift
//  JustNow
//

import AppKit
import CoreImage
import CoreVideo

/// Fast thumbnail generation using Core Graphics
func thumbnailFromPixelBuffer(_ buffer: CVPixelBuffer, maxSize: CGFloat) -> NSImage {
    let ciImage = CIImage(cvPixelBuffer: buffer)
    let context = CIContext(options: [.useSoftwareRenderer: false])

    let scale = maxSize / max(ciImage.extent.width, ciImage.extent.height)
    let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

    guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
        return NSImage()
    }

    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
}

/// Convert CVPixelBuffer to NSImage at full resolution
func imageFromPixelBuffer(_ buffer: CVPixelBuffer) -> NSImage {
    let ciImage = CIImage(cvPixelBuffer: buffer)
    let context = CIContext(options: [.useSoftwareRenderer: false])

    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
        return NSImage()
    }

    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
}

extension Collection {
    /// Safe subscript that returns nil for out-of-bounds indices
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
