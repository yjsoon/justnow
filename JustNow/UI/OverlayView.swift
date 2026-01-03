//
//  OverlayView.swift
//  JustNow
//

import SwiftUI
import CoreVideo
import Combine

class OverlayViewModel: ObservableObject {
    @Published var selectedIndex: Int = 0
    let frames: [StoredFrame]
    let onDismiss: () -> Void

    init(frames: [StoredFrame], onDismiss: @escaping () -> Void) {
        self.frames = frames
        self.onDismiss = onDismiss
        self.selectedIndex = max(0, frames.count - 1)
    }

    func moveLeft() {
        if selectedIndex > 0 {
            selectedIndex -= 1
        }
    }

    func moveRight() {
        if selectedIndex < frames.count - 1 {
            selectedIndex += 1
        }
    }

    func jumpLeft() {
        selectedIndex = max(0, selectedIndex - 10)
    }

    func jumpRight() {
        selectedIndex = min(frames.count - 1, selectedIndex + 10)
    }

    func goToStart() {
        selectedIndex = 0
    }

    func goToEnd() {
        selectedIndex = max(0, frames.count - 1)
    }
}

struct OverlayView: View {
    @StateObject private var viewModel: OverlayViewModel

    init(frames: [StoredFrame], onDismiss: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: OverlayViewModel(frames: frames, onDismiss: onDismiss))
    }

    var body: some View {
        KeyboardHandlingView(viewModel: viewModel) {
            ZStack {
                // Semi-transparent background
                Color.black.opacity(0.92)
                    .ignoresSafeArea()

                // Background tap to dismiss
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.onDismiss() }

                if viewModel.frames.isEmpty {
                    emptyStateView
                } else {
                    contentView
                }

                instructionsOverlay
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 64))
                .foregroundColor(.white.opacity(0.5))
            Text("No frames captured yet")
                .font(.title2)
                .foregroundColor(.white.opacity(0.7))
            Text("Keep the app running to build up history")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.5))
        }
    }

    private var contentView: some View {
        VStack(spacing: 0) {
            Spacer()

            // Main preview image
            if let frame = viewModel.frames[safe: viewModel.selectedIndex] {
                FramePreviewView(pixelBuffer: frame.pixelBuffer)
                    .padding(.horizontal, 60)
                    .padding(.top, 40)

                // Timestamp
                Text(timeAgoString(from: frame.timestamp))
                    .font(.system(size: 24, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.top, 16)

                // Frame counter
                Text("\(viewModel.selectedIndex + 1) / \(viewModel.frames.count)")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.top, 4)
            }

            Spacer()

            // Timeline scrubber at bottom
            TimelineScrubber(
                frames: viewModel.frames,
                selectedIndex: $viewModel.selectedIndex
            )
            .frame(height: 130)
            .padding(.horizontal, 20)
            .padding(.bottom, 50)
        }
    }

    private var instructionsOverlay: some View {
        VStack {
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("ESC to close")
                    Text("← → to navigate")
                    Text("Scroll to browse")
                }
                .font(.caption)
                .foregroundColor(.white.opacity(0.5))
                .padding()
            }
            Spacer()
        }
    }

    private func timeAgoString(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 {
            return "\(seconds)s ago"
        } else {
            return "\(seconds / 60)m \(seconds % 60)s ago"
        }
    }
}

struct FramePreviewView: View {
    let pixelBuffer: CVPixelBuffer

    var body: some View {
        Image(nsImage: imageFromPixelBuffer(pixelBuffer))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.5), radius: 20)
    }
}

// NSViewRepresentable to handle keyboard and scroll events
struct KeyboardHandlingView<Content: View>: NSViewRepresentable {
    let viewModel: OverlayViewModel
    let content: () -> Content

    func makeNSView(context: Context) -> KeyboardScrollView {
        let view = KeyboardScrollView()
        view.viewModel = viewModel
        view.autoresizingMask = [.width, .height]

        let hostingView = NSHostingView(rootView: content())
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: view.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        return view
    }

    func updateNSView(_ nsView: KeyboardScrollView, context: Context) {
        nsView.viewModel = viewModel
    }
}

class KeyboardScrollView: NSView {
    weak var viewModel: OverlayViewModel?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let viewModel = viewModel else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 123: // Left arrow
            if event.modifierFlags.contains(.command) {
                viewModel.goToStart()
            } else if event.modifierFlags.contains(.option) {
                viewModel.jumpLeft()
            } else {
                viewModel.moveLeft()
            }
        case 124: // Right arrow
            if event.modifierFlags.contains(.command) {
                viewModel.goToEnd()
            } else if event.modifierFlags.contains(.option) {
                viewModel.jumpRight()
            } else {
                viewModel.moveRight()
            }
        case 53: // ESC - handled in controller but just in case
            viewModel.onDismiss()
        default:
            super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let viewModel = viewModel else {
            super.scrollWheel(with: event)
            return
        }

        // Use horizontal scroll (trackpad swipe) or vertical scroll
        let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : -event.scrollingDeltaY

        if abs(delta) > 2 {
            if delta > 0 {
                viewModel.moveLeft()
            } else {
                viewModel.moveRight()
            }
        }
    }

    override func becomeFirstResponder() -> Bool {
        return true
    }
}
