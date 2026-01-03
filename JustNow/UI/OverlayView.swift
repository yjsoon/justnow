//
//  OverlayView.swift
//  JustNow
//

import SwiftUI
import CoreVideo

struct OverlayView: View {
    let frames: [StoredFrame]
    let onDismiss: () -> Void

    @State private var selectedIndex: Int = 0
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            // Background tap to dismiss
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            if frames.isEmpty {
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
            } else {
                VStack(spacing: 0) {
                    // Main preview image
                    if let frame = frames[safe: selectedIndex] {
                        FramePreviewView(pixelBuffer: frame.pixelBuffer)
                            .aspectRatio(contentMode: .fit)
                            .padding(40)

                        // Timestamp
                        Text(timeAgoString(from: frame.timestamp))
                            .font(.title2.monospacedDigit())
                            .foregroundColor(.white)
                            .padding(.bottom, 8)
                    }

                    Spacer()

                    // Timeline scrubber at bottom
                    TimelineScrubber(
                        frames: frames,
                        selectedIndex: $selectedIndex
                    )
                    .frame(height: 120)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
            }

            // Instructions overlay
            VStack {
                HStack {
                    Spacer()
                    Text("ESC to close")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                        .padding()
                }
                Spacer()
            }
        }
        .onExitCommand { onDismiss() } // Escape key
        .onAppear {
            // Start at most recent frame
            selectedIndex = max(0, frames.count - 1)
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    // Horizontal drag to scrub through time
                    let delta = Int(-value.translation.width / 30)
                    let newIndex = max(0, min(frames.count - 1, selectedIndex + delta))
                    if newIndex != selectedIndex {
                        selectedIndex = newIndex
                    }
                }
        )
        .gesture(
            MagnificationGesture()
                .onEnded { _ in
                    // Could implement zoom here
                }
        )
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
            .shadow(radius: 20)
    }
}
