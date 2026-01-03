//
//  OverlayView.swift
//  JustNow
//

import SwiftUI
import CoreVideo
import Observation

@Observable
class OverlayViewModel {
    var selectedIndex: Int = 0
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

    func scrollBy(_ delta: CGFloat) {
        let step = delta > 0 ? -1 : 1
        let newIndex = selectedIndex + step
        selectedIndex = max(0, min(frames.count - 1, newIndex))
    }
}

struct OverlayView: View {
    var viewModel: OverlayViewModel

    init(frames: [StoredFrame], onDismiss: @escaping () -> Void) {
        self.viewModel = OverlayViewModel(frames: frames, onDismiss: onDismiss)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.92)
                .ignoresSafeArea()

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { viewModel.onDismiss() }

            if viewModel.frames.isEmpty {
                EmptyStateView()
            } else {
                ContentAreaView(viewModel: viewModel)
            }

            InstructionsOverlay()
        }
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 64))
                .foregroundStyle(.white.opacity(0.5))
            Text("No frames captured yet")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.7))
            Text("Keep the app running to build up history")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

struct ContentAreaView: View {
    var viewModel: OverlayViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            if let frame = viewModel.frames[safe: viewModel.selectedIndex] {
                FramePreviewView(pixelBuffer: frame.pixelBuffer)
                    .padding(.horizontal, 60)
                    .padding(.top, 40)

                TimestampView(date: frame.timestamp)
                    .padding(.top, 20)
            }

            Spacer()

            TimelineSlider(viewModel: viewModel)
                .frame(height: 100)
                .padding(.horizontal, 40)
                .padding(.bottom, 60)
        }
    }
}

struct TimestampView: View {
    let date: Date

    var body: some View {
        let seconds = Int(Date().timeIntervalSince(date))
        let text = seconds < 60 ? "\(seconds)s ago" : "\(seconds / 60)m \(seconds % 60)s ago"

        Text(text)
            .font(.system(size: 28, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
    }
}

struct InstructionsOverlay: View {
    var body: some View {
        VStack {
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("ESC to close")
                    Text("← → to navigate")
                    Text("Scroll or drag slider")
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
                .padding()
            }
            Spacer()
        }
    }
}

struct FramePreviewView: View {
    let pixelBuffer: CVPixelBuffer

    var body: some View {
        Image(nsImage: imageFromPixelBuffer(pixelBuffer))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .clipShape(.rect(cornerRadius: 12))
            .shadow(color: .black.opacity(0.5), radius: 20)
    }
}

struct TimelineSlider: View {
    var viewModel: OverlayViewModel

    @State private var isDragging = false

    private var frameCount: Int { viewModel.frames.count }

    var body: some View {
        VStack(spacing: 12) {
            TimeLabels(frames: viewModel.frames)

            SliderTrack(
                frameCount: frameCount,
                selectedIndex: viewModel.selectedIndex,
                onIndexChanged: { viewModel.selectedIndex = $0 }
            )
            .frame(height: 20)

            Text("\(viewModel.selectedIndex + 1) / \(frameCount) frames")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

struct TimeLabels: View {
    let frames: [StoredFrame]

    var body: some View {
        HStack {
            if let oldest = frames.first {
                let seconds = Int(Date().timeIntervalSince(oldest.timestamp))
                let text = seconds < 60 ? "\(seconds)s ago" : "\(seconds / 60)m \(seconds % 60)s ago"
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Text("Now")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

struct SliderTrack: View {
    let frameCount: Int
    let selectedIndex: Int
    let onIndexChanged: (Int) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: 4)
                    .fill(.white.opacity(0.2))
                    .frame(height: 8)

                // Progress fill
                RoundedRectangle(cornerRadius: 4)
                    .fill(.white.opacity(0.5))
                    .frame(width: progressWidth(in: width), height: 8)

                // Thumb
                Circle()
                    .fill(.white)
                    .frame(width: 20, height: 20)
                    .shadow(radius: 4)
                    .offset(x: thumbOffset(in: width))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let percent = max(0, min(1, value.location.x / width))
                        let newIndex = Int(percent * CGFloat(frameCount - 1))
                        onIndexChanged(newIndex)
                    }
            )
        }
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        guard frameCount > 1 else { return 0 }
        let percent = CGFloat(selectedIndex) / CGFloat(frameCount - 1)
        return totalWidth * percent
    }

    private func thumbOffset(in totalWidth: CGFloat) -> CGFloat {
        guard frameCount > 1 else { return 0 }
        let percent = CGFloat(selectedIndex) / CGFloat(frameCount - 1)
        return (totalWidth - 20) * percent
    }
}
