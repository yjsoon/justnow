import CoreGraphics
import SwiftUI

/// Draws a CGImage scaled into its frame. Uses a SwiftUI Canvas so no
/// NSViewRepresentable-driven intrinsic size can leak up the layout tree —
/// that feedback path grew the overlay unboundedly on macOS 26 when different
/// displays produced frames with different pixel dimensions.
private struct ScaledFrameImageView: View {
    let image: CGImage

    var body: some View {
        Canvas { context, size in
            let swiftUIImage = Image(decorative: image, scale: 1, orientation: .up)
            context.draw(swiftUIImage, in: CGRect(origin: .zero, size: size))
        }
    }
}

struct FramePreviewView: View {
    let frame: StoredFrame
    let viewModel: OverlayViewModel
    let frameBuffer: FrameBuffer
    @Binding var textGrabBannerState: TextGrabBannerState

    @AppStorage(AppStorageKey.textGrabSoundEnabled) private var textGrabSoundEnabled: Bool = AppStorageDefault.textGrabSoundEnabled
    @AppStorage(AppStorageKey.textGrabDebugPreviewEnabled) private var textGrabDebugPreviewEnabled: Bool = AppStorageDefault.textGrabDebugPreviewEnabled
    @State private var image: CGImage?
    @State private var loadedFrameID: UUID?
    @State private var isLoading = false
    @State private var showsDeferredLoadOverlay = false
    @State private var loadFailed = false
    @State private var searchTextLayout: SearchTextLayout?
    @State private var textGrabDebugSnapshot: TextGrabDebugSnapshot?
    @State private var loadOverlayTask: Task<Void, Never>?

    private let loadIndicatorDelay: Duration = .milliseconds(140)

    private var shouldShowSearchHighlights: Bool {
        viewModel.isSearchAvailable && viewModel.isSearching && viewModel.hasSearchQuery
    }

    private var isShowingCurrentFrame: Bool {
        loadedFrameID == frame.id
    }

    private var searchHighlightLoadKey: String {
        "\(frame.id.uuidString)|\(shouldShowSearchHighlights)|\(isShowingCurrentFrame ? "ready" : "pending")"
    }

    var body: some View {
        Group {
            if let image = image {
                GeometryReader { proxy in
                    let fitted = fittedSize(for: image, in: proxy.size)
                    ScaledFrameImageView(image: image)
                        .frame(width: fitted.width, height: fitted.height)
                        .overlay {
                            if isShowingCurrentFrame, shouldShowSearchHighlights, let searchTextLayout {
                                SearchHighlightOverlay(
                                    image: image,
                                    layout: searchTextLayout,
                                    query: viewModel.searchQuery
                                )
                                .allowsHitTesting(false)
                            }
                        }
                        .overlay {
                            if isShowingCurrentFrame {
                                TextGrabSelectionOverlay(
                                    image: image,
                                    viewModel: viewModel,
                                    soundEnabled: textGrabSoundEnabled,
                                    debugCaptureEnabled: textGrabDebugPreviewEnabled,
                                    bannerState: $textGrabBannerState,
                                    debugSnapshot: $textGrabDebugSnapshot
                                )
                                .id(frame.id)
                            }
                        }
                        .overlay(alignment: .bottomLeading) {
                            if isShowingCurrentFrame, textGrabDebugPreviewEnabled, let textGrabDebugSnapshot {
                                TextGrabDebugPreview(snapshot: textGrabDebugSnapshot)
                                    .padding(20)
                                    .allowsHitTesting(false)
                            }
                        }
                        .overlay {
                            if showsDeferredLoadOverlay && isLoading && !isShowingCurrentFrame {
                                Rectangle()
                                    .fill(.black.opacity(0.045))
                            }
                        }
                        .clipShape(.rect(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.5), radius: 30)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.white.opacity(0.05))
                    .aspectRatio(16/10, contentMode: .fit)
                    .overlay {
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                        } else if loadFailed {
                            VStack(spacing: 8) {
                                Image(systemName: "photo.badge.exclamationmark")
                                    .font(.title)
                                Text("Frame removed")
                                    .font(.caption)
                            }
                            .foregroundStyle(.white.opacity(0.3))
                        }
                    }
            }
        }
        .task(id: frame.id) {
            loadOverlayTask?.cancel()
            loadOverlayTask = nil
            isLoading = true
            showsDeferredLoadOverlay = false
            loadFailed = false
            searchTextLayout = nil
            textGrabBannerState = .hint
            textGrabDebugSnapshot = nil

            if image != nil {
                loadOverlayTask = Task {
                    try? await Task.sleep(for: loadIndicatorDelay)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        if isLoading && !isShowingCurrentFrame {
                            showsDeferredLoadOverlay = true
                        }
                    }
                }
            }

            do {
                let loadedImage = try await frameBuffer.getFullImage(for: frame)
                guard !Task.isCancelled else { return }
                loadOverlayTask?.cancel()
                loadOverlayTask = nil
                image = loadedImage
                loadedFrameID = frame.id
                viewModel.setPresentedFrame(frame)
            } catch is CancellationError {
                loadOverlayTask?.cancel()
                loadOverlayTask = nil
                return
            } catch {
                guard !Task.isCancelled else { return }
                loadOverlayTask?.cancel()
                loadOverlayTask = nil
                image = nil
                loadedFrameID = nil
                loadFailed = true
                viewModel.setPresentedFrame(nil)
            }

            guard !Task.isCancelled else { return }
            isLoading = false
            showsDeferredLoadOverlay = false
        }
        .onChange(of: textGrabDebugPreviewEnabled) { _, isEnabled in
            if !isEnabled {
                textGrabDebugSnapshot = nil
            }
        }
        .task(id: searchHighlightLoadKey) {
            guard shouldShowSearchHighlights, isShowingCurrentFrame, let image else {
                searchTextLayout = nil
                return
            }

            let layout = await frameBuffer.getSearchLayout(for: frame, image: image)
            guard !Task.isCancelled else { return }
            searchTextLayout = layout
        }
    }

    private func aspectRatio(of image: CGImage) -> CGFloat {
        let width = max(1, CGFloat(image.width))
        let height = max(1, CGFloat(image.height))
        return width / height
    }

    private func fittedSize(for image: CGImage, in available: CGSize) -> CGSize {
        guard available.width > 0, available.height > 0 else { return .zero }
        let aspect = aspectRatio(of: image)
        if available.width / available.height > aspect {
            let height = available.height
            return CGSize(width: height * aspect, height: height)
        }
        let width = available.width
        return CGSize(width: width, height: width / aspect)
    }
}

private struct SearchHighlightOverlay: View {
    let image: CGImage
    let layout: SearchTextLayout
    let query: String

    private let rectPadding: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            let displayedSize = proxy.size
            let displayedImageRect =
                TextGrabGeometry.displayedImageRect(
                    for: CGSize(width: image.width, height: image.height),
                    fittedWithin: displayedSize
                ) ?? CGRect(origin: .zero, size: displayedSize)
            let highlightRects = layout.highlightRects(matching: query)

            ZStack(alignment: .topLeading) {
                ForEach(Array(highlightRects.enumerated()), id: \.offset) { _, normalisedRect in
                    let displayedRect = TextGrabGeometry.paddedDisplayedRect(
                        forNormalisedImageRect: normalisedRect,
                        displayedImageRect: displayedImageRect,
                        padding: rectPadding
                    )
                    let cornerRadius = max(10, min(displayedRect.width, displayedRect.height) * 0.22)

                    if displayedRect.width > 0, displayedRect.height > 0 {
                        RoundedRectangle(
                            cornerRadius: cornerRadius,
                            style: .continuous
                        )
                        .fill(Color(red: 1.0, green: 0.82, blue: 0.14).opacity(0.18))
                        .overlay {
                            ZStack {
                                RoundedRectangle(
                                    cornerRadius: cornerRadius,
                                    style: .continuous
                                )
                                .stroke(Color.black.opacity(0.36), lineWidth: 4)

                                RoundedRectangle(
                                    cornerRadius: cornerRadius,
                                    style: .continuous
                                )
                                .stroke(Color(red: 1.0, green: 0.93, blue: 0.52).opacity(0.96), lineWidth: 2)
                            }
                        }
                        .shadow(color: Color.black.opacity(0.18), radius: 5)
                        .frame(width: displayedRect.width, height: displayedRect.height)
                        .offset(x: displayedRect.minX, y: displayedRect.minY)
                    }
                }
            }
        }
    }
}
