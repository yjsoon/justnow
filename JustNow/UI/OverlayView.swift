//
//  OverlayView.swift
//  JustNow
//

import SwiftUI
import CoreGraphics

private enum OverlayChromeMetrics {
    static let controlSize: CGFloat = 40
    static let topPadding: CGFloat = 24
    static let horizontalPadding: CGFloat = 28
    static let contentSpacing: CGFloat = 12
    static let sideSlotWidth: CGFloat = controlSize
    static let searchBarTopPadding: CGFloat = topPadding + controlSize + contentSpacing
}

struct OverlayView: View {
    var viewModel: OverlayViewModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            Button(action: viewModel.onDismiss) {
                Color.clear
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel("Dismiss overlay")
            .accessibilityHint("Closes the timeline overlay.")

            CompatGlassEffectContainer(spacing: 40) {
                ZStack {
                    if !viewModel.hasAnyFrames {
                        EmptyStateView()
                    } else {
                        ContentAreaView(viewModel: viewModel)
                    }

                    OverlayTopBar(viewModel: viewModel)
                }
            }
        }
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 64))
                .foregroundStyle(.white.opacity(0.7))
            Text("No frames captured yet")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.9))
            Text("Keep the app running to build up history")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(32)
        .compatGlassEffect(cornerRadius: 20)
    }
}

struct ContentAreaView: View {
    var viewModel: OverlayViewModel

    private var displayedFrames: [StoredFrame] { viewModel.displayedFrames }
    @State private var textGrabBannerState: TextGrabBannerState = .hint

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isSearchAvailable && viewModel.isSearching {
                SearchBarView(viewModel: viewModel)
                    .padding(.top, OverlayChromeMetrics.searchBarTopPadding)
                    .padding(.horizontal, 200)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Spacer()

            if let frame = displayedFrames[safe: viewModel.selectedIndex] {
                HStack(spacing: 20) {
                    OverlayChromeButton(
                        systemImage: "chevron.left",
                        accessibilityLabel: "Previous frame",
                        accessibilityHint: "Shows the next older captured frame.",
                        toolTip: "Previous frame (Left Arrow)",
                        isEnabled: viewModel.canMoveLeft,
                        action: viewModel.moveLeft
                    )

                    FramePreviewView(
                        frame: frame,
                        viewModel: viewModel,
                        frameBuffer: viewModel.frameBuffer,
                        textGrabBannerState: $textGrabBannerState
                    )
                    .frame(maxWidth: .infinity)

                    OverlayChromeButton(
                        systemImage: "chevron.right",
                        accessibilityLabel: "Next frame",
                        accessibilityHint: "Shows the next newer captured frame.",
                        toolTip: "Next frame (Right Arrow)",
                        isEnabled: viewModel.canMoveRight,
                        action: viewModel.moveRight
                    )
                }
                .padding(.horizontal, 60)
                .padding(.top, viewModel.isSearchAvailable && viewModel.isSearching ? 20 : 40)
            } else if !viewModel.isSearching && viewModel.timelineFrames.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("No frames in this rewind window")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.6))
                    Text(
                        viewModel.isSearchAvailable
                            ? "Search can still look through all indexed history."
                            : "Increase rewind history in Settings to keep older frames visible here."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.45))
                }
            } else if viewModel.shouldShowSearchingState {
                SearchSearchingStateView()
            } else if viewModel.shouldShowNoSearchResults {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("No matches found")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.6))
                    Text("Try a different word or broaden the time range.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            Spacer()

            TimelineSlider(viewModel: viewModel, textGrabBannerState: textGrabBannerState)
                .frame(height: 100)
                .padding(.horizontal, 40)
                .padding(.bottom, 50)
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.isSearchAvailable && viewModel.isSearching)
        .task(id: viewModel.selectedFramePrefetchKey) {
            viewModel.prefetchImagesNearSelection()
        }
        .onChange(of: viewModel.selectedIndex) { _, _ in
            textGrabBannerState = .hint
        }
        .onChange(of: displayedFrames.count) { _, frameCount in
            if frameCount == 0 {
                textGrabBannerState = .hint
            }
        }
    }
}

private struct OverlayTopBar: View {
    var viewModel: OverlayViewModel

    @ViewBuilder
    private var searchControl: some View {
        if viewModel.isSearchAvailable {
            OverlayChromeButton(
                systemImage: "magnifyingglass",
                accessibilityLabel: viewModel.isSearching ? "Close search" : "Open search",
                accessibilityHint: viewModel.isSearching
                    ? "Closes search and returns to the full timeline."
                    : "Opens the search field for indexed screen text.",
                toolTip: viewModel.isSearching ? "Close search (Escape)" : "Search (/)",
                isSelected: viewModel.isSearching,
                action: viewModel.toggleSearch
            )
        } else {
            Color.clear
                .frame(width: OverlayChromeMetrics.controlSize, height: OverlayChromeMetrics.controlSize)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    var body: some View {
        VStack {
            HStack(spacing: 16) {
                OverlayChromeButton(
                    systemImage: "xmark",
                    accessibilityLabel: "Close overlay",
                    accessibilityHint: "Dismisses the rewind overlay.",
                    toolTip: "Close (\u{238B})",
                    action: viewModel.onDismiss
                )
                .frame(width: OverlayChromeMetrics.sideSlotWidth, alignment: .leading)

                InstructionsOverlay()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .layoutPriority(1)

                searchControl
                    .frame(width: OverlayChromeMetrics.sideSlotWidth, alignment: .trailing)
            }
            .padding(.horizontal, OverlayChromeMetrics.horizontalPadding)
            .padding(.top, OverlayChromeMetrics.topPadding)

            Spacer()
        }
    }
}

private struct OverlayChromeButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let accessibilityHint: String
    let toolTip: String
    var isEnabled: Bool = true
    var isSelected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(foregroundStyle)
                .frame(width: 40, height: 40)
                .background(backgroundFill, in: Circle())
                .overlay {
                    Circle()
                        .stroke(borderColor, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(toolTip)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private var foregroundStyle: Color {
        isSelected ? .black.opacity(0.88) : .white.opacity(isEnabled ? 0.86 : 0.46)
    }

    private var backgroundFill: Color {
        if isSelected {
            return Color.white.opacity(0.95)
        }
        return Color.black.opacity(0.72)
    }

    private var borderColor: Color {
        isSelected ? .white.opacity(0.42) : .white.opacity(0.1)
    }
}

private struct CompatGlassEffectContainer<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if LEGACY_MACOS_UI
        content()
            .padding(spacing)
        #else
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
                .padding(spacing)
        }
        #endif
    }
}

private extension View {
    @ViewBuilder
    func compatGlassEffect(cornerRadius: CGFloat) -> some View {
        #if LEGACY_MACOS_UI
        self.background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(.ultraThinMaterial)
        )
        #else
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.ultraThinMaterial)
            )
        }
        #endif
    }
}

struct SearchBarView: View {
    var viewModel: OverlayViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.6))

            TextField("Search screen text...", text: Bindable(viewModel).searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .focused($isFocused)
                .onChange(of: viewModel.searchQuery) { _, _ in
                    viewModel.performSearch()
                }
                .onSubmit {
                    viewModel.performSearch(immediately: true)
                }

            if viewModel.isSearchLoading {
                SearchingStatusBadge()
            } else if !viewModel.searchResults.isEmpty {
                let status = viewModel.searchIndexStatus
                let indexPercent = status.totalFrames > 0
                    ? Int(round(Double(status.indexedFrames) / Double(status.totalFrames) * 100))
                    : 100
                if indexPercent < 100 {
                    Text("\(viewModel.searchResults.count) found · \(indexPercent)% indexed")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    Text("\(viewModel.searchResults.count) found")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            } else {
                let status = viewModel.searchIndexStatus
                let indexPercent = status.totalFrames > 0
                    ? Int(round(Double(status.indexedFrames) / Double(status.totalFrames) * 100))
                    : 100
                if indexPercent < 100 {
                    Text("\(indexPercent)% indexed")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }

            Button {
                viewModel.clearSearch()
            } label: {
                Label("Clear search", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(SearchTimeScope.allCases, id: \.self) { scope in
                    Button {
                        viewModel.searchTimeScope = scope
                        if viewModel.hasSearchQuery {
                            viewModel.performSearch(immediately: true)
                        }
                    } label: {
                        if scope == viewModel.searchTimeScope {
                            Label(scope.label(using: viewModel.rewindHistoryOption), systemImage: "checkmark")
                        } else {
                            Text(scope.label(using: viewModel.rewindHistoryOption))
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(viewModel.searchTimeScope.compactLabel(using: viewModel.rewindHistoryOption))
                        .font(.caption)
                        .fontWeight(.medium)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .darkBarBackground(in: Capsule())
        .onAppear { isFocused = true }
        .task {
            while !Task.isCancelled {
                await viewModel.refreshIndexStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

private struct SearchSearchingStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            SearchingRippleBar(height: 16)
                .frame(width: 240)

            Text("Searching")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))

            Text("Looking through indexed screen text as you type")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.52))
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .darkBarBackground(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct SearchingStatusBadge: View {
    var body: some View {
        HStack(spacing: 8) {
            SearchingRippleBar(height: 10)
                .frame(width: 54)

            Text("Searching…")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.68))
        }
    }
}

private struct SearchingRippleBar: View {
    private let trackColor = Color.white.opacity(0.08)
    private let borderColor = Color.white.opacity(0.14)
    private let rippleColors = [
        Color(red: 0.36, green: 0.78, blue: 0.74).opacity(0.15),
        Color(red: 0.95, green: 0.77, blue: 0.43).opacity(0.34),
        Color(red: 0.45, green: 0.69, blue: 0.95).opacity(0.18),
    ]

    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                let duration = 3.8
                let progress = (context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: duration)) / duration
                let glowWidth = max(proxy.size.width * 0.72, 44)
                let travel = proxy.size.width + glowWidth
                let offset = -glowWidth + travel * progress

                Capsule(style: .continuous)
                    .fill(trackColor)
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(borderColor, lineWidth: 1)
                    }
                    .overlay(alignment: .leading) {
                        LinearGradient(colors: rippleColors, startPoint: .leading, endPoint: .trailing)
                            .frame(width: glowWidth)
                            .blur(radius: height * 0.75)
                            .offset(x: offset)
                            .blendMode(.screen)
                    }
                    .clipShape(Capsule(style: .continuous))
            }
        }
        .frame(height: height)
    }
}

struct InstructionsOverlay: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            instructionPill(textGrabLabel: "drag to grab text", showsSearchShortcut: FeatureFlags.isSearchEnabled)
            instructionPill(textGrabLabel: "grab text", showsSearchShortcut: FeatureFlags.isSearchEnabled)
            instructionPill(textGrabLabel: "grab", showsSearchShortcut: FeatureFlags.isSearchEnabled)
            instructionPill(textGrabLabel: "", showsSearchShortcut: FeatureFlags.isSearchEnabled)
        }
    }

    private func instructionPill(textGrabLabel: String, showsSearchShortcut: Bool) -> some View {
        HStack(spacing: 16) {
            Label("← →", systemImage: "arrow.left.arrow.right")
            if textGrabLabel.isEmpty {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                Label(textGrabLabel, systemImage: "text.viewfinder")
            }
            if showsSearchShortcut {
                Label("/", systemImage: "magnifyingglass")
            }
        }
        .labelStyle(CompactInstructionLabelStyle())
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.7))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .darkBarBackground(in: Capsule())
    }
}

struct CompactInstructionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
            configuration.title
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
