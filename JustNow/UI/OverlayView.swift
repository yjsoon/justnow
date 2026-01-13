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

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { viewModel.onDismiss() }

            GlassEffectContainer(spacing: 40) {
                ZStack {
                    if viewModel.frames.isEmpty {
                        EmptyStateView()
                    } else {
                        ContentAreaView(viewModel: viewModel)
                    }

                    InstructionsOverlay()
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
            }

            Spacer()

            TimelineSlider(viewModel: viewModel)
                .frame(height: 100)
                .padding(.horizontal, 40)
                .padding(.bottom, 50)
        }
    }
}

struct InstructionsOverlay: View {
    var body: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 16) {
                    Label("ESC", systemImage: "escape")
                    Label("← →", systemImage: "arrow.left.arrow.right")
                    Label("Scroll", systemImage: "scroll")
                }
                .labelStyle(CompactInstructionLabelStyle())
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding()
            }
            Spacer()
        }
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

    private var frameCount: Int { viewModel.frames.count }

    private var currentFrame: StoredFrame? {
        viewModel.frames[safe: viewModel.selectedIndex]
    }

    var body: some View {
        VStack(spacing: 12) {
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

            // Combined footer: frame count + timestamp
            HStack(spacing: 6) {
                Text("\(viewModel.selectedIndex + 1) / \(frameCount)")
                    .fontWeight(.medium)
                if let frame = currentFrame {
                    Text("·")
                        .foregroundStyle(.white.opacity(0.4))
                    Text(formatRelativeTime(frame.timestamp))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .font(.system(size: 13, design: .monospaced))
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

// Cached formatters for date formatting
private let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return formatter
}()

private let dayTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE h:mm a"
    return formatter
}()

private let dateTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "d MMM h:mm a"
    return formatter
}()

/// Format timestamp as relative time or absolute time for older frames
private func formatRelativeTime(_ date: Date) -> String {
    let seconds = Int(Date().timeIntervalSince(date))

    if seconds < 60 {
        return "\(seconds)s ago"
    }
    if seconds < 3600 {
        return "\(seconds / 60)m \(seconds % 60)s ago"
    }
    if seconds < 7200 {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return "\(h)h \(m)m \(s)s ago"
    }

    // Show absolute time with context
    let calendar = Calendar.current

    if calendar.isDateInToday(date) {
        return timeFormatter.string(from: date)
    }
    if calendar.isDateInYesterday(date) {
        return "Yesterday \(timeFormatter.string(from: date))"
    }

    let daysAgo = calendar.dateComponents([.day], from: date, to: Date()).day ?? 0
    if daysAgo < 7 {
        return dayTimeFormatter.string(from: date)
    }
    return dateTimeFormatter.string(from: date)
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
