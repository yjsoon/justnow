//
//  OverlayView.swift
//  JustNow
//

import SwiftUI
import CoreGraphics
import Observation

@Observable
class OverlayViewModel {
    var selectedIndex: Int = 0
    let frames: [StoredFrame]
    let frameBuffer: FrameBuffer
    let onDismiss: () -> Void

    init(frames: [StoredFrame], frameBuffer: FrameBuffer, onDismiss: @escaping () -> Void) {
        self.frames = frames
        self.frameBuffer = frameBuffer
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

    init(frames: [StoredFrame], frameBuffer: FrameBuffer, onDismiss: @escaping () -> Void) {
        self.viewModel = OverlayViewModel(frames: frames, frameBuffer: frameBuffer, onDismiss: onDismiss)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { viewModel.onDismiss() }

            GlassEffectContainer(spacing: 40) {
                if viewModel.frames.isEmpty {
                    EmptyStateView()
                } else {
                    ContentAreaView(viewModel: viewModel)
                }
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
                .foregroundStyle(.white.opacity(0.7))
            Text("No frames captured yet")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.9))
            Text("Keep the app running to build up history")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(32)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

struct ContentAreaView: View {
    var viewModel: OverlayViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            if let frame = viewModel.frames[safe: viewModel.selectedIndex] {
                FramePreviewView(frame: frame, frameBuffer: viewModel.frameBuffer)
                    .padding(.horizontal, 60)
                    .padding(.top, 40)

                TimestampView(date: frame.timestamp)
                    .padding(.top, 20)
            }

            Spacer()

            TimelineSlider(viewModel: viewModel)
                .frame(height: 120)
                .padding(.horizontal, 40)
                .padding(.bottom, 60)
        }
    }
}

struct TimestampView: View {
    let date: Date

    var body: some View {
        Text(formatRelativeTime(date))
            .font(.system(size: 28, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
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
                .foregroundStyle(.white.opacity(0.8))
                .padding(12)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .padding()
            }
            Spacer()
        }
    }
}

struct FramePreviewView: View {
    let frame: StoredFrame
    let frameBuffer: FrameBuffer

    @State private var image: CGImage?
    @State private var isLoading = false
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: imageFromCGImage(image))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
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
            isLoading = true
            loadFailed = false
            image = nil

            do {
                image = try await frameBuffer.getFullImage(for: frame)
            } catch {
                loadFailed = true
            }

            isLoading = false
        }
    }
}

struct TimelineSlider: View {
    var viewModel: OverlayViewModel

    @State private var isDragging = false

    private var frameCount: Int { viewModel.frames.count }

    var body: some View {
        VStack(spacing: 16) {
            TimeLabels(frames: viewModel.frames)

            SliderTrack(
                frameCount: frameCount,
                selectedIndex: viewModel.selectedIndex,
                onIndexChanged: { viewModel.selectedIndex = $0 }
            )
            .frame(height: 32)
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))

            Text("\(viewModel.selectedIndex + 1) / \(frameCount) frames")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}

struct TimeLabels: View {
    let frames: [StoredFrame]

    var body: some View {
        HStack {
            if let oldest = frames.first {
                Text(formatRelativeTime(oldest.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Text("Now")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

/// Format timestamp as relative time or absolute time for older frames
private func formatRelativeTime(_ date: Date) -> String {
    let seconds = Int(Date().timeIntervalSince(date))

    if seconds < 60 {
        return "\(seconds)s ago"
    } else if seconds < 3600 {
        return "\(seconds / 60)m \(seconds % 60)s ago"
    } else if seconds < 7200 {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return "\(h)h \(m)m \(s)s ago"
    } else {
        // Show absolute time with context
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let timeStr = formatter.string(from: date)

        if calendar.isDateInToday(date) {
            return timeStr
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday \(timeStr)"
        } else {
            // Show day of week for this week, or date for older
            let daysAgo = calendar.dateComponents([.day], from: date, to: Date()).day ?? 0
            if daysAgo < 7 {
                formatter.dateFormat = "EEE h:mm a"  // "Mon 2:34 PM"
            } else {
                formatter.dateFormat = "d MMM h:mm a"  // "10 Jan 2:34 PM"
            }
            return formatter.string(from: date)
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
                    .fill(.white.opacity(0.6))
                    .frame(width: progressWidth(in: width), height: 8)

                // Thumb
                Circle()
                    .fill(.white)
                    .frame(width: 24, height: 24)
                    .shadow(color: .black.opacity(0.3), radius: 4)
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
        return (totalWidth - 24) * percent
    }
}
