//
//  TextGrabSelectionOverlay.swift
//  JustNow
//

import AppKit
import SwiftUI

struct TextGrabDebugSnapshot {
    let image: CGImage
    let cropRect: CGRect

    var pixelSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }
}

enum TextGrabBannerState: Equatable {
    case hint
    case processing
    case copied(preview: String)
    case noTextFound
    case failed

    var title: String {
        switch self {
        case .hint:
            return "Drag to grab text"
        case .processing:
            return "Copying text…"
        case .copied:
            return "Copied to clipboard"
        case .noTextFound:
            return "No text found"
        case .failed:
            return "Couldn’t grab text"
        }
    }

    var subtitle: String? {
        switch self {
        case .hint:
            return nil
        case .processing:
            return "Release the selection and JustNow will clean it up for you."
        case .copied(let preview):
            return preview
        case .noTextFound:
            return "Try a tighter selection around the words you want."
        case .failed:
            return "Try again on a sharper frame."
        }
    }

    var symbolName: String {
        switch self {
        case .hint:
            return "text.viewfinder"
        case .processing:
            return "text.viewfinder"
        case .copied:
            return "checkmark.circle.fill"
        case .noTextFound:
            return "exclamationmark.magnifyingglass"
        case .failed:
            return "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .hint, .processing:
            return .white
        case .copied:
            return Color(red: 0.72, green: 0.92, blue: 0.78)
        case .noTextFound:
            return Color(red: 1.0, green: 0.85, blue: 0.56)
        case .failed:
            return Color(red: 1.0, green: 0.72, blue: 0.72)
        }
    }

    var showsProgress: Bool {
        if case .processing = self {
            return true
        }
        return false
    }
}

struct TextGrabSelectionOverlay: View {
    let image: CGImage
    let soundEnabled: Bool
    let debugCaptureEnabled: Bool
    @Binding var bannerState: TextGrabBannerState
    @Binding var debugSnapshot: TextGrabDebugSnapshot?

    @State private var selectionRect: CGRect?
    @State private var isProcessing = false
    @State private var selectionTask: Task<Void, Never>?
    @State private var bannerResetTask: Task<Void, Never>?
    @State private var hasCrosshairCursor = false

    var body: some View {
        GeometryReader { proxy in
            let displayedSize = proxy.size
            let displayedImageRect =
                TextGrabGeometry.displayedImageRect(
                    for: CGSize(width: image.width, height: image.height),
                    fittedWithin: displayedSize
                ) ?? CGRect(origin: .zero, size: displayedSize)

            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onHover { isInside in
                        updateCrosshairCursor(isInside: isInside, isEnabled: !isProcessing)
                    }
                    .gesture(selectionGesture(displayedImageRect: displayedImageRect))

                if let selectionRect {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(isProcessing ? 0.08 : 0.04))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(
                                    Color.white.opacity(isProcessing ? 0.74 : 0.42),
                                    lineWidth: 1.25
                                )
                        }
                        .frame(width: selectionRect.width, height: selectionRect.height)
                        .offset(x: selectionRect.minX, y: selectionRect.minY)
                        .overlay {
                            if isProcessing {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(.white)
                            }
                        }
                }
            }
        }
        .onDisappear {
            selectionTask?.cancel()
            bannerResetTask?.cancel()
            selectionRect = nil
            debugSnapshot = nil
            bannerState = .hint
            releaseCrosshairCursor()
        }
    }

    private func selectionGesture(displayedImageRect: CGRect) -> some Gesture {
        return DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard !isProcessing else { return }
                guard displayedImageRect.contains(value.startLocation) else {
                    selectionRect = nil
                    return
                }

                selectionRect = TextGrabGeometry.selectionRect(
                    from: value.startLocation,
                    to: value.location,
                    within: displayedImageRect
                )
            }
            .onEnded { value in
                guard !isProcessing else { return }
                guard displayedImageRect.contains(value.startLocation) else {
                    selectionRect = nil
                    return
                }

                let finalRect = TextGrabGeometry.selectionRect(
                    from: value.startLocation,
                    to: value.location,
                    within: displayedImageRect
                )

                guard finalRect.width >= TextGrabGeometry.minimumDisplaySelectionLength,
                      finalRect.height >= TextGrabGeometry.minimumDisplaySelectionLength else {
                    selectionRect = nil
                    updateBanner(.hint)
                    return
                }

                selectionRect = finalRect
                beginTextGrab(for: finalRect, displayedImageRect: displayedImageRect)
            }
    }

    private func beginTextGrab(for selectionRect: CGRect, displayedImageRect: CGRect) {
        guard let cropRect = TextGrabGeometry.cropRect(
            for: selectionRect,
            displayedImageRect: displayedImageRect,
            imageSize: CGSize(width: image.width, height: image.height)
        ), let croppedImage = image.cropping(to: cropRect) else {
            self.selectionRect = nil
            debugSnapshot = nil
            updateBanner(.failed, resetAfter: .seconds(2.4))
            return
        }

        selectionTask?.cancel()
        isProcessing = true
        updateCrosshairCursor(isInside: false, isEnabled: false)
        if debugCaptureEnabled {
            debugSnapshot = TextGrabDebugSnapshot(image: croppedImage, cropRect: cropRect)
        } else {
            debugSnapshot = nil
        }
        updateBanner(.processing)

        selectionTask = Task {
            let text = await TextRecognitionManager.extractText(from: croppedImage, mode: .selection)
            guard !Task.isCancelled else { return }

            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

            await MainActor.run {
                self.selectionRect = nil
                self.isProcessing = false

                guard !trimmedText.isEmpty else {
                    self.updateBanner(.noTextFound, resetAfter: .seconds(2.4))
                    return
                }

                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()

                guard pasteboard.setString(trimmedText, forType: .string) else {
                    self.updateBanner(.failed, resetAfter: .seconds(2.4))
                    return
                }

                self.playCopySoundIfNeeded()
                self.updateBanner(
                    .copied(preview: Self.previewSnippet(for: trimmedText)),
                    resetAfter: .seconds(2.8)
                )
            }
        }
    }

    private func updateBanner(_ state: TextGrabBannerState, resetAfter duration: Duration? = nil) {
        bannerResetTask?.cancel()
        bannerState = state

        guard let duration else { return }
        bannerResetTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                bannerState = .hint
            }
        }
    }

    private func playCopySoundIfNeeded() {
        guard soundEnabled, let sound = NSSound(named: .init("Glass")) else { return }
        sound.stop()
        sound.play()
    }

    private func updateCrosshairCursor(isInside: Bool, isEnabled: Bool) {
        if isInside, isEnabled, !hasCrosshairCursor {
            NSCursor.crosshair.push()
            hasCrosshairCursor = true
        } else if (!isInside || !isEnabled), hasCrosshairCursor {
            NSCursor.pop()
            hasCrosshairCursor = false
        }
    }

    private func releaseCrosshairCursor() {
        guard hasCrosshairCursor else { return }
        NSCursor.pop()
        hasCrosshairCursor = false
    }

    private static func previewSnippet(for text: String) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        if singleLine.count <= 72 {
            return singleLine
        }

        let cutoff = singleLine.index(singleLine.startIndex, offsetBy: 72)
        return "\(singleLine[..<cutoff])…"
    }
}

struct TextGrabToast: View {
    let state: TextGrabBannerState

    var body: some View {
        if state != .hint {
            HStack(alignment: .center, spacing: 10) {
                if state.showsProgress {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: state.symbolName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(state.tint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)

                    if let subtitle = state.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Color.black.opacity(0.62), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
    }
}

struct TextGrabDebugPreview: View {
    let snapshot: TextGrabDebugSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Text-grab debug")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)

            Image(nsImage: imageFromCGImage(snapshot.image))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 220, maxHeight: 140)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                }

            Text(debugMetadata)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.58))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private var debugMetadata: String {
        let size = snapshot.pixelSize
        return """
        OCR input \(Int(size.width))×\(Int(size.height)) px
        crop \(Int(snapshot.cropRect.minX)),\(Int(snapshot.cropRect.minY))
        """
    }
}
