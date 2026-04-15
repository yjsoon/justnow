import CoreGraphics
import SwiftUI

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
                ZStack {
                    Image(nsImage: imageFromCGImage(image))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .overlay {
                            ZStack {
                                if isShowingCurrentFrame, shouldShowSearchHighlights, let searchTextLayout {
                                    SearchHighlightOverlay(
                                        image: image,
                                        layout: searchTextLayout,
                                        query: viewModel.searchQuery
                                    )
                                    .allowsHitTesting(false)
                                }

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
                }
                .clipShape(.rect(cornerRadius: 16))
                .shadow(color: .black.opacity(0.5), radius: 30)
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
