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

// MARK: - Screenshot Cursor

/// A cursor designed to look like the macOS screenshot capture cursor.
/// Shows a compact target with dark strokes and a faint white outline.
enum ScreenshotCursor {
    static let shared: NSCursor = {
        let size: CGFloat = 44
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let ctx = NSGraphicsContext.current?.cgContext
            guard let context = ctx else { return false }

            let center = CGPoint(x: rect.midX, y: rect.midY)
            let armRadius: CGFloat = 14
            let centerGapRadius: CGFloat = 1.5
            let centerRingRadius: CGFloat = 6.4

            let drawTargetArms: (NSColor, CGFloat) -> Void = { color, lineWidth in
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(lineWidth)
                context.setLineCap(.round)

                context.move(to: CGPoint(x: center.x - armRadius, y: center.y))
                context.addLine(to: CGPoint(x: center.x - centerGapRadius, y: center.y))
                context.move(to: CGPoint(x: center.x + centerGapRadius, y: center.y))
                context.addLine(to: CGPoint(x: center.x + armRadius, y: center.y))

                context.move(to: CGPoint(x: center.x, y: center.y - armRadius))
                context.addLine(to: CGPoint(x: center.x, y: center.y - centerGapRadius))
                context.move(to: CGPoint(x: center.x, y: center.y + centerGapRadius))
                context.addLine(to: CGPoint(x: center.x, y: center.y + armRadius))

                context.strokePath()
            }

            let drawCenterRing: (NSColor, CGFloat) -> Void = { color, lineWidth in
                let ringRect = CGRect(
                    x: center.x - centerRingRadius,
                    y: center.y - centerRingRadius,
                    width: centerRingRadius * 2,
                    height: centerRingRadius * 2
                )
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(lineWidth)
                context.strokeEllipse(in: ringRect)
            }

            drawTargetArms(NSColor.white.withAlphaComponent(0.39), 3)
            drawCenterRing(NSColor.white.withAlphaComponent(0.39), 2.9)

            drawTargetArms(NSColor.black.withAlphaComponent(0.96), 1.7)
            drawCenterRing(NSColor.black.withAlphaComponent(0.96), 1.6)

            return true
        }

        return NSCursor(image: image, hotSpot: NSPoint(x: size / 2, y: size / 2))
    }()
}

struct TextGrabSelectionOverlay: View {
    let image: CGImage
    let viewModel: OverlayViewModel
    let soundEnabled: Bool
    let debugCaptureEnabled: Bool
    @Binding var bannerState: TextGrabBannerState
    @Binding var debugSnapshot: TextGrabDebugSnapshot?

    @State private var selectionRect: CGRect?
    @State private var isProcessing = false
    @State private var selectionTask: Task<Void, Never>?
    @State private var bannerResetTask: Task<Void, Never>?
    @State private var hasScreenshotCursor = false
    @State private var pointerLocation: CGPoint?
    @State private var displayedImageRectSnapshot: CGRect = .zero
    @State private var isCurrentDragCancelled = false

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
                    .gesture(selectionGesture(displayedImageRect: displayedImageRect))
                    .overlay(
                        PointerTrackingView { phase in
                            handlePointerPhase(phase, displayedImageRect: displayedImageRect)
                        }
                    )

                if let selectionRect {
                    SelectionBox(isProcessing: isProcessing)
                        .frame(width: selectionRect.width, height: selectionRect.height)
                        .offset(x: selectionRect.minX, y: selectionRect.minY)
                }
            }
            .onAppear {
                displayedImageRectSnapshot = displayedImageRect
                viewModel.setTextGrabCancellationHandler(cancelTextGrab)
                syncTextGrabState()
            }
            .onChange(of: selectionRect) { _, _ in
                syncTextGrabState()
            }
            .onChange(of: isProcessing) { _, _ in
                syncTextGrabState()
                reevaluateCursor(displayedImageRect: displayedImageRect)
            }
            .onChange(of: displayedImageRect) { _, newDisplayedImageRect in
                displayedImageRectSnapshot = newDisplayedImageRect
                reevaluateCursor(displayedImageRect: newDisplayedImageRect)
            }
        }
            .onDisappear {
            selectionTask?.cancel()
            bannerResetTask?.cancel()
            viewModel.isTextGrabActive = false
            viewModel.setTextGrabCancellationHandler(nil)
            selectionRect = nil
            isCurrentDragCancelled = false
            pointerLocation = nil
            displayedImageRectSnapshot = .zero
            debugSnapshot = nil
            bannerState = .hint
            releaseScreenshotCursor()
        }
    }

    private func selectionGesture(displayedImageRect: CGRect) -> some Gesture {
        return DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard !isProcessing else { return }
                guard !isCurrentDragCancelled else {
                    selectionRect = nil
                    return
                }
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
                guard !isCurrentDragCancelled else {
                    isCurrentDragCancelled = false
                    selectionRect = nil
                    updateBanner(.hint)
                    return
                }
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
        updateScreenshotCursor(isInsideImage: false, isEnabled: false)
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

    private func updateScreenshotCursor(isInsideImage: Bool, isEnabled: Bool) {
        let shouldShowScreenshotCursor = isInsideImage && isEnabled

        if shouldShowScreenshotCursor {
            if !hasScreenshotCursor {
                ScreenshotCursor.shared.push()
                hasScreenshotCursor = true
            }
            ScreenshotCursor.shared.set()
        } else if hasScreenshotCursor {
            NSCursor.pop()
            NSCursor.current.set()
            hasScreenshotCursor = false
        }
    }

    private func releaseScreenshotCursor() {
        guard hasScreenshotCursor else { return }
        NSCursor.pop()
        NSCursor.current.set()
        hasScreenshotCursor = false
    }

    private func handlePointerPhase(_ phase: PointerTrackingView.Phase, displayedImageRect: CGRect) {
        switch phase {
        case .active(let location):
            pointerLocation = location
            updateScreenshotCursor(
                isInsideImage: displayedImageRect.contains(location),
                isEnabled: !isProcessing
            )
        case .ended:
            pointerLocation = nil
            updateScreenshotCursor(isInsideImage: false, isEnabled: false)
        }
    }

    private func reevaluateCursor(displayedImageRect: CGRect) {
        guard let pointerLocation else {
            updateScreenshotCursor(isInsideImage: false, isEnabled: false)
            return
        }

        updateScreenshotCursor(
            isInsideImage: displayedImageRect.contains(pointerLocation),
            isEnabled: !isProcessing
        )
    }

    private func syncTextGrabState() {
        viewModel.isTextGrabActive = selectionRect != nil || isProcessing
    }

    private func cancelTextGrab() {
        if selectionRect != nil && !isProcessing {
            isCurrentDragCancelled = true
        }
        selectionTask?.cancel()
        selectionTask = nil
        bannerResetTask?.cancel()
        bannerResetTask = nil
        selectionRect = nil
        isProcessing = false
        debugSnapshot = nil
        updateBanner(.hint)
        reevaluateCursor(displayedImageRect: displayedImageRectSnapshot)
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

private struct PointerTrackingView: NSViewRepresentable {
    enum Phase {
        case active(CGPoint)
        case ended
    }

    let onPhaseChange: (Phase) -> Void

    func makeNSView(context: Context) -> PointerTrackingNSView {
        let view = PointerTrackingNSView()
        view.onPhaseChange = onPhaseChange
        return view
    }

    func updateNSView(_ nsView: PointerTrackingNSView, context: Context) {
        nsView.onPhaseChange = onPhaseChange
    }
}

private final class PointerTrackingNSView: NSView {
    var onPhaseChange: ((PointerTrackingView.Phase) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var mouseMovedMonitor: Any?
    private var keyWindowObserver: NSObjectProtocol?

    override var isFlipped: Bool { true }

    deinit {
        tearDownWindowTracking()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let options: NSTrackingArea.Options = [
            .activeAlways,
            .inVisibleRect,
            .mouseEnteredAndExited,
            .mouseMoved
        ]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area

        refreshPointerLocation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tearDownWindowTracking()
        window?.acceptsMouseMovedEvents = true
        setUpWindowTracking()
        refreshPointerLocation()
    }

    override func mouseEntered(with event: NSEvent) {
        publishActivePhase(for: event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        publishActivePhase(for: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        onPhaseChange?(.ended)
    }

    func refreshPointerLocation() {
        guard let window else {
            onPhaseChange?(.ended)
            return
        }

        let localPoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(localPoint) {
            onPhaseChange?(.active(localPoint))
        } else {
            onPhaseChange?(.ended)
        }
    }

    private func publishActivePhase(for locationInWindow: CGPoint) {
        let localPoint = convert(locationInWindow, from: nil)
        if bounds.contains(localPoint) {
            onPhaseChange?(.active(localPoint))
        } else {
            onPhaseChange?(.ended)
        }
    }

    private func setUpWindowTracking() {
        guard let window else { return }

        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.refreshPointerLocation()
            DispatchQueue.main.async {
                self?.refreshPointerLocation()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self?.refreshPointerLocation()
            }
        }

        mouseMovedMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            self.publishActivePhase(for: event.locationInWindow)
            return event
        }
    }

    private func tearDownWindowTracking() {
        if let mouseMovedMonitor {
            NSEvent.removeMonitor(mouseMovedMonitor)
            self.mouseMovedMonitor = nil
        }

        if let keyWindowObserver {
            NotificationCenter.default.removeObserver(keyWindowObserver)
            self.keyWindowObserver = nil
        }
    }
}

// MARK: - Selection Box View

/// A macOS-style selection box with high-contrast borders that work on all backgrounds.
/// Features: semi-transparent dark fill, bright white inner border, dark outer shadow for contrast.
struct SelectionBox: View {
    let isProcessing: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(isProcessing ? 0.2 : 0.14))

            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(isProcessing ? 0.7 : 0.58), lineWidth: 1.8)
                .shadow(color: Color.black.opacity(0.5), radius: 3, x: 0, y: 1)
        }
        .overlay {
            if isProcessing {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.2)
            }
        }
    }
}
