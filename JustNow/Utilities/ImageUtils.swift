//
//  ImageUtils.swift
//  JustNow
//

import AppKit

/// Convert CGImage to NSImage
func imageFromCGImage(_ cgImage: CGImage) -> NSImage {
    NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
}

extension Collection {
    /// Safe subscript that returns nil for out-of-bounds indices
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
