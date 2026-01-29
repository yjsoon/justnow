//
//  OverlayView.swift
//  JustNow
//

import SwiftUI
import CoreGraphics
import Observation
import os.log

private let logger = Logger(subsystem: "sg.tk.JustNow", category: "OverlayView")

@Observable
class OverlayViewModel {
    var selectedIndex: Int = 0
    let frames: [StoredFrame]
    let frameBuffer: FrameBuffer
    let onDismiss: () -> Void

    // Search state
    var isSearching = false
    var searchQuery = ""
    var searchResults: [StoredFrame] = []
    var isSearchInProgress = false
    var searchProgress: Double = 0
    private var searchTask: Task<Void, Never>?

    /// Frames to display (filtered if searching, all otherwise)
    var displayedFrames: [StoredFrame] {
        isSearching && !searchQuery.isEmpty ? searchResults : frames
    }

    init(frames: [StoredFrame], frameBuffer: FrameBuffer, onDismiss: @escaping () -> Void) {
        self.frames = frames
        self.frameBuffer = frameBuffer
        self.onDismiss = onDismiss
        self.selectedIndex = max(0, frames.count - 1)
    }

    func toggleSearch() {
        print("[JustNow] toggleSearch called, isSearching was: \(isSearching)")
        isSearching.toggle()
        print("[JustNow] isSearching is now: \(isSearching)")
        if !isSearching {
            clearSearch()
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchQuery = ""
        searchResults = []
        isSearchInProgress = false
        searchProgress = 0
        // Reset to end of full frames
        selectedIndex = max(0, frames.count - 1)
    }

    func performSearch() {
        print("[JustNow] performSearch() called with query: '\(searchQuery)'")
        searchTask?.cancel()
        guard !searchQuery.isEmpty else {
            print("[JustNow] Query is empty, returning")
            searchResults = []
            return
        }

        logger.info("Starting search for: '\(self.searchQuery)' in \(self.frames.count) frames")
        print("[JustNow] Starting search for: '\(searchQuery)' in \(frames.count) frames")

        isSearchInProgress = true
        searchProgress = 0
        searchResults = []

        let query = searchQuery // Capture locally for task
        let framesToSearch = frames
        let buffer = frameBuffer
        let cache = frameBuffer.textCache

        searchTask = Task {
            let total = framesToSearch.count
            var processedCount = 0
            var matches: [(index: Int, frame: StoredFrame)] = []
            var cacheHits = 0
            var cacheMisses = 0

            // Process frames in parallel batches
            let batchSize = 8 // Process 8 frames concurrently

            for batchStart in stride(from: 0, to: total, by: batchSize) {
                if Task.isCancelled { break }

                let batchEnd = min(batchStart + batchSize, total)
                let batch = Array(framesToSearch[batchStart..<batchEnd])

                // Process batch in parallel
                await withTaskGroup(of: (Int, StoredFrame, Bool, Bool).self) { group in
                    for (offset, frame) in batch.enumerated() {
                        let globalIndex = batchStart + offset
                        group.addTask {
                            // Check cache first
                            if let cachedText = await cache.getText(for: frame.id) {
                                let contains = cachedText.localizedCaseInsensitiveContains(query)
                                return (globalIndex, frame, contains, true) // true = cache hit
                            }

                            // Cache miss - run OCR
                            guard let image = try? await buffer.getFullImage(for: frame) else {
                                return (globalIndex, frame, false, false)
                            }
                            let text = await TextRecognitionManager.extractText(from: image)

                            // Cache the result
                            await cache.setText(text, for: frame.id)

                            let contains = text.localizedCaseInsensitiveContains(query)
                            return (globalIndex, frame, contains, false) // false = cache miss
                        }
                    }

                    for await (index, frame, contains, wasCached) in group {
                        if wasCached { cacheHits += 1 } else { cacheMisses += 1 }
                        if contains {
                            matches.append((index, frame))
                        }
                    }
                }

                processedCount = batchEnd
                await MainActor.run {
                    searchProgress = Double(processedCount) / Double(total)
                }
            }

            // Save cache periodically
            await cache.save()

            // Sort matches by index to maintain chronological order
            matches.sort { $0.index < $1.index }
            let sortedFrames = matches.map { $0.frame }

            print("[JustNow] Search complete: \(sortedFrames.count) matches, \(cacheHits) cache hits, \(cacheMisses) OCR runs")

            await MainActor.run {
                if !Task.isCancelled {
                    searchResults = sortedFrames
                    isSearchInProgress = false
                    if !sortedFrames.isEmpty {
                        selectedIndex = sortedFrames.count - 1
                    }
                }
            }
        }
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

    private var displayedFrames: [StoredFrame] { viewModel.displayedFrames }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            if viewModel.isSearching {
                SearchBarView(viewModel: viewModel)
                    .padding(.top, 60)
                    .padding(.horizontal, 200)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Spacer()

            if let frame = displayedFrames[safe: viewModel.selectedIndex] {
                FramePreviewView(frame: frame, frameBuffer: viewModel.frameBuffer)
                    .padding(.horizontal, 60)
                    .padding(.top, viewModel.isSearching ? 20 : 40)
            } else if viewModel.isSearching && displayedFrames.isEmpty && !viewModel.isSearchInProgress {
                // No results state
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("No matches found")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            Spacer()

            TimelineSlider(viewModel: viewModel)
                .frame(height: 100)
                .padding(.horizontal, 40)
                .padding(.bottom, 50)
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.isSearching)
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
                .onSubmit {
                    print("[JustNow] onSubmit triggered, query: '\(viewModel.searchQuery)'")
                    viewModel.performSearch()
                }

            if viewModel.isSearchInProgress {
                ProgressView(value: viewModel.searchProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 60)
                    .tint(.white)
            } else if !viewModel.searchResults.isEmpty {
                Text("\(viewModel.searchResults.count) found")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }

            Button {
                viewModel.clearSearch()
                viewModel.isSearching = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .darkBarBackground(in: Capsule())
        .onAppear { isFocused = true }
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
                    Label("/", systemImage: "magnifyingglass")
                }
                .labelStyle(CompactInstructionLabelStyle())
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .darkBarBackground(in: Capsule())
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

    private var displayedFrames: [StoredFrame] { viewModel.displayedFrames }
    private var frameCount: Int { displayedFrames.count }

    private var currentFrame: StoredFrame? {
        displayedFrames[safe: viewModel.selectedIndex]
    }

    var body: some View {
        VStack(spacing: 12) {
            TimeLabels(frames: displayedFrames)

            SliderTrack(
                frameCount: frameCount,
                selectedIndex: viewModel.selectedIndex,
                onIndexChanged: { viewModel.selectedIndex = $0 }
            )
            .frame(height: 32)
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
            .darkBarBackground(in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            // Combined footer: frame count + timestamp + search indicator
            HStack(spacing: 6) {
                if viewModel.isSearching && !viewModel.searchQuery.isEmpty {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
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

private let barBackgroundColor = Color.black.opacity(0.85)
private let barBorderColor = Color.white.opacity(0.08)

private extension View {
    func darkBarBackground<S: InsettableShape>(in shape: S) -> some View {
        background(barBackgroundColor, in: shape)
            .overlay(shape.stroke(barBorderColor, lineWidth: 1))
    }
}

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
