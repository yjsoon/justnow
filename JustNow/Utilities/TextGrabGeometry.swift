//
//  TextGrabGeometry.swift
//  JustNow
//

import CoreGraphics

enum TextGrabGeometry {
    static let minimumDisplaySelectionLength: CGFloat = 18

    static func selectionRect(from start: CGPoint, to end: CGPoint, within bounds: CGRect) -> CGRect {
        let clampedStart = clamp(start, within: bounds)
        let clampedEnd = clamp(end, within: bounds)

        return CGRect(
            x: min(clampedStart.x, clampedEnd.x),
            y: min(clampedStart.y, clampedEnd.y),
            width: abs(clampedEnd.x - clampedStart.x),
            height: abs(clampedEnd.y - clampedStart.y)
        )
    }

    static func displayedImageRect(for imageSize: CGSize, fittedWithin containerSize: CGSize) -> CGRect? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        guard containerSize.width > 0, containerSize.height > 0 else { return nil }

        let widthScale = containerSize.width / imageSize.width
        let heightScale = containerSize.height / imageSize.height
        let scale = min(widthScale, heightScale)

        let fittedSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )

        return CGRect(
            x: (containerSize.width - fittedSize.width) / 2,
            y: (containerSize.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    static func cropRect(
        for selectionRect: CGRect,
        displayedImageRect: CGRect,
        imageSize: CGSize,
        paddingFraction: CGFloat = 0.02,
        minimumPadding: CGFloat = 0
    ) -> CGRect? {
        guard selectionRect.width > 0, selectionRect.height > 0 else { return nil }
        guard displayedImageRect.width > 0, displayedImageRect.height > 0 else { return nil }
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }

        let clampedSelection = selectionRect.intersection(displayedImageRect)
        guard clampedSelection.width > 0, clampedSelection.height > 0 else { return nil }

        let relativeSelection = CGRect(
            x: clampedSelection.minX - displayedImageRect.minX,
            y: clampedSelection.minY - displayedImageRect.minY,
            width: clampedSelection.width,
            height: clampedSelection.height
        )

        let scaleX = imageSize.width / displayedImageRect.width
        let scaleY = imageSize.height / displayedImageRect.height
        let padding = max(
            minimumPadding,
            min(relativeSelection.width, relativeSelection.height) * paddingFraction
        )

        var imageRect = CGRect(
            x: relativeSelection.minX * scaleX,
            y: relativeSelection.minY * scaleY,
            width: relativeSelection.width * scaleX,
            height: relativeSelection.height * scaleY
        )
        imageRect = imageRect.insetBy(dx: -padding * scaleX, dy: -padding * scaleY)

        let imageBounds = CGRect(origin: .zero, size: imageSize)
        let clamped = imageRect.integral.intersection(imageBounds)
        guard clamped.width > 0, clamped.height > 0 else { return nil }
        return clamped
    }

    static func displayedRect(
        forNormalisedImageRect normalisedRect: CGRect,
        displayedImageRect: CGRect
    ) -> CGRect {
        let clampedRect = CGRect(
            x: min(max(normalisedRect.minX, 0), 1),
            y: min(max(normalisedRect.minY, 0), 1),
            width: min(max(normalisedRect.width, 0), 1),
            height: min(max(normalisedRect.height, 0), 1)
        )

        return CGRect(
            x: displayedImageRect.minX + clampedRect.minX * displayedImageRect.width,
            y: displayedImageRect.minY + (1 - clampedRect.maxY) * displayedImageRect.height,
            width: clampedRect.width * displayedImageRect.width,
            height: clampedRect.height * displayedImageRect.height
        )
    }

    static func paddedDisplayedRect(
        forNormalisedImageRect normalisedRect: CGRect,
        displayedImageRect: CGRect,
        padding: CGFloat
    ) -> CGRect {
        let baseRect = displayedRect(
            forNormalisedImageRect: normalisedRect,
            displayedImageRect: displayedImageRect
        )
        guard padding > 0 else { return baseRect }

        let expandedRect = baseRect.insetBy(dx: -padding, dy: -padding)
        let clampedRect = expandedRect.intersection(displayedImageRect)
        guard !clampedRect.isNull else { return .zero }
        return clampedRect
    }

    private static func clamp(_ point: CGPoint, within bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }
}
