//
//  OverlayView.swift
//  JustNow
//

import CoreGraphics
import SwiftUI

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

private struct OverlayBackdropView: View {
    let viewModel: OverlayViewModel
    @State private var backdropImage: NSImage?

    private var presentedFrame: StoredFrame? {
        viewModel.presentedFrame
    }

    var body: some View {
        ZStack {
            if let backdropImage {
                Image(nsImage: backdropImage)
                    .resizable()
                    .scaledToFill()
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
                viewModel.setPresentedFrame(nil)
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
