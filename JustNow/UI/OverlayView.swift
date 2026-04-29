//
//  OverlayView.swift
//  JustNow
//

import AppKit
import CoreGraphics
import SwiftUI

private enum OverlayChromeMetrics {
    static let controlSize: CGFloat = 40
    static let topPadding: CGFloat = 29
    static let horizontalPadding: CGFloat = 28
    static let contentSpacing: CGFloat = 12
    static let sideSlotWidth: CGFloat = controlSize
    static let searchBarTopPadding: CGFloat = topPadding + controlSize + contentSpacing
    static let contentVerticalShift: CGFloat = 28
    static let timelineBottomPadding: CGFloat = 50
    static let timelineFooterBottomPadding: CGFloat = 7
}

struct OverlayView: View {
    var viewModel: OverlayViewModel

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            OverlayBackdropView(viewModel: viewModel)
                .ignoresSafeArea()

            Button(action: viewModel.onDismiss) {
                Color.clear
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel("Dismiss overlay")
            .accessibilityHint("Closes the timeline overlay.")

            if !viewModel.hasAnyFrames {
                CompatGlassEffectContainer(spacing: 40) {
                    EmptyStateView()
                }
            } else {
                ContentAreaView(viewModel: viewModel)
            }

            OverlayTopBar(viewModel: viewModel)
        }
        .overlay(alignment: .top) {
            if let toast = viewModel.saveToast {
                OverlayToastView(toast: toast) { url in
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    viewModel.dismissSaveToast()
                }
                    .padding(.top, 90)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
                    .id(toast.id)
            }
        }
        .animation(.easeOut(duration: 0.22), value: viewModel.saveToast?.id)
    }
}

private struct OverlayToastView: View {
    let toast: OverlayToast
    let onReveal: (URL) -> Void

    @State private var isHovering = false

    var body: some View {
        if let url = toast.revealURL {
            Button {
                onReveal(url)
            } label: {
                toastContent
            }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .accessibilityLabel(Text(toast.title))
            .accessibilityHint(Text("Click to reveal in Finder."))
        } else {
            toastContent
        }
    }

    private var toastContent: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(toast.isError ? Color.red.opacity(0.9) : Color.green.opacity(0.9))
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                if let detail = toast.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .darkBarBackground(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            if isHovering {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

private struct OverlayBackdropView: View {
    let viewModel: OverlayViewModel
    @State private var backdropImage: CGImage?

    private var presentedFrame: StoredFrame? {
        viewModel.presentedFrame
    }

    var body: some View {
        ZStack {
            if let backdropImage {
                // Canvas gives us explicit, intrinsic-free layout — avoids the
                // Image.scaledToFill overflow that leaked image pixel dims
                // up the hierarchy and grew the root layout on macOS 26.
                Canvas { context, size in
                    guard size.width > 0, size.height > 0 else { return }
                    let imageAspect = CGFloat(backdropImage.width) / CGFloat(max(1, backdropImage.height))
                    let frameAspect = size.width / size.height
                    let drawRect: CGRect
                    if imageAspect > frameAspect {
                        let scaledWidth = size.height * imageAspect
                        drawRect = CGRect(
                            x: (size.width - scaledWidth) / 2,
                            y: 0,
                            width: scaledWidth,
                            height: size.height
                        )
                    } else {
                        let scaledHeight = size.width / imageAspect
                        drawRect = CGRect(
                            x: 0,
                            y: (size.height - scaledHeight) / 2,
                            width: size.width,
                            height: scaledHeight
                        )
                    }
                    context.draw(Image(decorative: backdropImage, scale: 1, orientation: .up), in: drawRect)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .saturation(0.6)
                .blur(radius: 28)
                .opacity(0.15)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: presentedFrame?.id)
        .task(id: presentedFrame?.id) {
            guard let presentedFrame else {
                backdropImage = nil
                return
            }

            let thumbnail = await viewModel.frameBuffer.getThumbnail(for: presentedFrame)
            guard !Task.isCancelled else { return }
            backdropImage = thumbnail
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

            centerContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, viewModel.isSearchAvailable && viewModel.isSearching ? 20 : 40)
                .offset(y: OverlayChromeMetrics.contentVerticalShift)

            TimelineSlider(viewModel: viewModel)
                .padding(.horizontal, 40)
                .padding(.bottom, OverlayChromeMetrics.timelineBottomPadding)
        }
        .overlay(alignment: .bottom) {
            TimelineFooter(viewModel: viewModel, textGrabBannerState: textGrabBannerState)
                .padding(.bottom, OverlayChromeMetrics.timelineFooterBottomPadding)
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
                viewModel.setPresentedFrame(nil)
            }
        }
    }

    @ViewBuilder
    private var centerContent: some View {
        if let frame = displayedFrames[safe: viewModel.selectedIndex] {
            GeometryReader { row in
                let chevronWidth: CGFloat = 40
                let interitem: CGFloat = 20
                let previewWidth = max(0, row.size.width - (chevronWidth * 2) - (interitem * 2))
                HStack(spacing: interitem) {
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
                    .frame(width: previewWidth, height: row.size.height)

                    OverlayChromeButton(
                        systemImage: "chevron.right",
                        accessibilityLabel: "Next frame",
                        accessibilityHint: "Shows the next newer captured frame.",
                        toolTip: "Next frame (Right Arrow)",
                        isEnabled: viewModel.canMoveRight,
                        action: viewModel.moveRight
                    )
                }
                .frame(width: row.size.width, height: row.size.height)
            }
            .padding(.horizontal, 60)
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

                HStack(spacing: 12) {
                    InstructionsOverlay()
                    if viewModel.availableDisplays.count > 1 {
                        DisplayPickerStrip(viewModel: viewModel)
                    }
                    OverlayMoreMenuIsland(viewModel: viewModel)
                }
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

private struct DisplayPickerStrip: View {
    var viewModel: OverlayViewModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(viewModel.availableDisplays, id: \.id) { display in
                DisplayChip(
                    display: display,
                    isActive: viewModel.activeDisplay?.id == display.id,
                    action: { viewModel.switchDisplay(to: display) }
                )
            }

            Text("Tab")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.leading, 2)
                .padding(.top, 2)
                .offset(y: -1)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .darkBarBackground(in: Capsule())
    }
}

private struct DisplayChip: View {
    let display: DisplayInfo
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if !display.isConnected {
                    Image(systemName: "clock")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(foregroundStyle.opacity(0.7))
                }
                Text(display.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(foregroundStyle)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(backgroundFill))
        }
        .buttonStyle(.plain)
        .help(display.isConnected ? "Show \(display.name) (Tab)" : "Show \(display.name) — disconnected, historical only (Tab)")
        .accessibilityLabel(display.isConnected ? "Switch to \(display.name)" : "Switch to \(display.name) (historical)")
    }

    private var foregroundStyle: Color {
        if isActive {
            return Color.black.opacity(0.9)
        }
        return display.isConnected ? Color.white.opacity(0.7) : Color.white.opacity(0.45)
    }

    private var backgroundFill: Color {
        isActive ? Color.white.opacity(0.6) : Color.clear
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
                        .stroke(borderColor, lineWidth: 1.25)
                }
                .shadow(color: .black.opacity(isSelected ? 0.2 : 0.32), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(toolTip)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private var foregroundStyle: Color {
        isSelected ? .black.opacity(0.9) : .white.opacity(isEnabled ? 0.96 : 0.5)
    }

    private var backgroundFill: Color {
        if isSelected {
            return Color.white.opacity(0.96)
        }
        return Color.white.opacity(0.16)
    }

    private var borderColor: Color {
        isSelected ? .white.opacity(0.52) : .white.opacity(0.28)
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
