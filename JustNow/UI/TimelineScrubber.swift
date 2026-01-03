//
//  TimelineScrubber.swift
//  JustNow
//

import SwiftUI
import CoreVideo

struct TimelineScrubber: View {
    let frames: [StoredFrame]
    @Binding var selectedIndex: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(Array(frames.enumerated()), id: \.element.id) { index, frame in
                        ThumbnailView(
                            pixelBuffer: frame.pixelBuffer,
                            isSelected: index == selectedIndex,
                            timestamp: frame.timestamp
                        )
                        .id(index)
                        .onTapGesture { selectedIndex = index }
                    }
                }
                .padding(.horizontal, 20)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
            .onAppear {
                // Scroll to selected on appear
                proxy.scrollTo(selectedIndex, anchor: .center)
            }
        }
    }
}

struct ThumbnailView: View {
    let pixelBuffer: CVPixelBuffer
    let isSelected: Bool
    let timestamp: Date

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: thumbnailFromPixelBuffer(pixelBuffer, maxSize: 160))
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 160, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.white : Color.clear, lineWidth: 3)
                )
                .scaleEffect(isSelected ? 1.05 : 1.0)
                .animation(.easeOut(duration: 0.15), value: isSelected)

            Text(timeAgoString(from: timestamp))
                .font(.caption2)
                .foregroundColor(isSelected ? .white : .white.opacity(0.7))
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
