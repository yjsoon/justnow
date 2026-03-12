//
//  OverlayView.swift
//  JustNow
//

import SwiftUI
import CoreGraphics
import Observation
import os.log

private let logger = Logger(subsystem: "sg.tk.JustNow", category: "OverlayView")

enum SearchTimeScope: String, CaseIterable {
    case fiveMinutes
    case oneHour
    case rewindHistory
    case all

    var label: String {
        switch self {
        case .fiveMinutes:
            return "Last 5m"
        case .oneHour:
            return "Last 1h"
        case .rewindHistory:
            return RewindHistoryOption.defaultValue.searchLabel
        case .all:
            return "All"
        }
    }

    var compactLabel: String {
        switch self {
        case .fiveMinutes:
            return "5m"
        case .oneHour:
            return "1h"
        case .rewindHistory:
            return RewindHistoryOption.defaultValue.compactSearchLabel
        case .all:
            return "All"
        }
    }

    func label(using option: RewindHistoryOption) -> String {
        switch self {
        case .fiveMinutes:
            return "Last 5m"
        case .oneHour:
            return "Last 1h"
        case .rewindHistory:
            return option.searchLabel
        case .all:
            return "All"
        }
    }

    func compactLabel(using option: RewindHistoryOption) -> String {
        switch self {
        case .fiveMinutes:
            return "5m"
        case .oneHour:
            return "1h"
        case .rewindHistory:
            return option.compactSearchLabel
        case .all:
            return "All"
        }
    }

    func cutoff(using option: RewindHistoryOption, from now: Date = Date()) -> Date? {
        switch self {
        case .fiveMinutes:
            return now.addingTimeInterval(-5 * 60)
        case .oneHour:
            return now.addingTimeInterval(-60 * 60)
        case .rewindHistory:
            return now.addingTimeInterval(-option.duration)
        case .all:
            return nil
        }
    }
}

@Observable
@MainActor
class OverlayViewModel {
    var selectedIndex: Int = 0
    let timelineFrames: [StoredFrame]
    let searchableFrames: [StoredFrame]
    let frameBuffer: FrameBuffer
    let recentTimelineWindow: TimeInterval
    let rewindHistoryOption: RewindHistoryOption
    let timelineReferenceDate: Date
    let onDismiss: () -> Void

    // Search state
    var isSearching = false
    var searchQuery = ""
    var searchTimeScope: SearchTimeScope = .all
    var searchResults: [StoredFrame] = []
    var isSearchInProgress = false
    var searchProgress: Double = 0
    private var searchTask: Task<Void, Never>?

    /// Frames to display (filtered if searching, all otherwise)
    var displayedFrames: [StoredFrame] {
        isSearching && !searchQuery.isEmpty ? searchResults : timelineFrames
    }

    var displayedFrameCount: Int {
        displayedFrames.count
    }

    var hasAnyFrames: Bool {
        !timelineFrames.isEmpty || !searchableFrames.isEmpty
    }

    init(
        timelineFrames: [StoredFrame],
        searchableFrames: [StoredFrame],
        frameBuffer: FrameBuffer,
        recentTimelineWindow: TimeInterval,
        rewindHistoryOption: RewindHistoryOption,
        onDismiss: @escaping () -> Void
    ) {
        self.timelineFrames = timelineFrames
        self.searchableFrames = searchableFrames
        self.frameBuffer = frameBuffer
        self.recentTimelineWindow = recentTimelineWindow
        self.rewindHistoryOption = rewindHistoryOption
        self.timelineReferenceDate = Date()
        self.onDismiss = onDismiss
        self.selectedIndex = max(0, timelineFrames.count - 1)
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
        selectedIndex = max(0, timelineFrames.count - 1)
    }

    func performSearch() {
        print("[JustNow] performSearch() called with query: '\(searchQuery)'")
        searchTask?.cancel()
        guard !searchQuery.isEmpty else {
            print("[JustNow] Query is empty, returning")
            searchResults = []
            return
        }

        logger.info("Starting search for: '\(self.searchQuery)' in \(self.searchableFrames.count) frames")
        print("[JustNow] Starting search for: '\(searchQuery)' in \(searchableFrames.count) frames")

        isSearchInProgress = true
        searchProgress = 0
        searchResults = []

        let query = searchQuery // Capture locally for task
        let scope = searchTimeScope
        let searchCutoff = scope.cutoff(using: rewindHistoryOption)
        let framesToSearch = searchCutoff.map { cutoff in
            searchableFrames.filter { $0.timestamp >= cutoff }
        } ?? searchableFrames
        let buffer = frameBuffer
        let cache = frameBuffer.textCache
        let searchStartedAt = Date()

        searchTask = Task {
            let total = framesToSearch.count
            guard total > 0 else {
                await MainActor.run {
                    searchResults = []
                    searchProgress = 1
                    isSearchInProgress = false
                }
                return
            }

            let allFrameIDs = framesToSearch.map(\.id)
            let cachedIDs = await cache.cachedFrameIDs(in: allFrameIDs)
            let uncachedFrames = framesToSearch.filter { !cachedIDs.contains($0.id) }

            var processedCount = 0
            var ocrRuns = 0
            var loadFailures = 0

            // Process frames in parallel batches
            let batchSize = 8 // Process 8 frames concurrently
            let uncachedTotal = uncachedFrames.count

            if uncachedTotal == 0 {
                await MainActor.run {
                    searchProgress = 1
                }
            }

            for batchStart in stride(from: 0, to: uncachedTotal, by: batchSize) {
                if Task.isCancelled { return }

                let batchEnd = min(batchStart + batchSize, uncachedTotal)
                let batch = Array(uncachedFrames[batchStart..<batchEnd])

                // Process batch in parallel
                await withTaskGroup(of: Bool.self) { group in
                    for frame in batch {
                        group.addTask {
                            guard let image = try? await buffer.getFullImage(for: frame) else {
                                return false
                            }
                            let text = await TextRecognitionManager.extractText(from: image)

                            // Persist OCR text to indexed cache
                            await cache.setText(text, for: frame.id, timestamp: frame.timestamp)
                            return true
                        }
                    }

                    for await didOCR in group {
                        if didOCR {
                            ocrRuns += 1
                        } else {
                            loadFailures += 1
                        }
                    }
                }

                processedCount = batchEnd
                let completed = processedCount
                await MainActor.run {
                    searchProgress = uncachedTotal == 0 ? 1 : Double(completed) / Double(uncachedTotal)
                }
            }

            guard !Task.isCancelled else { return }

            // Save cache periodically
            await cache.save()

            guard !Task.isCancelled else { return }

            let matchedIDs = await cache.searchFrameIDs(matching: query, limit: total, since: searchCutoff)
            let frameByID = Dictionary(uniqueKeysWithValues: framesToSearch.map { ($0.id, $0) })
            var seenIDs: Set<UUID> = []
            var sortedFrames: [StoredFrame] = []
            sortedFrames.reserveCapacity(matchedIDs.count)

            for matchedID in matchedIDs {
                guard seenIDs.insert(matchedID).inserted else { continue }
                guard let frame = frameByID[matchedID] else { continue }
                sortedFrames.append(frame)
            }

            guard !Task.isCancelled else { return }

            let searchDuration = Date().timeIntervalSince(searchStartedAt)
            await SearchTelemetry.shared.recordSearch(
                duration: searchDuration,
                wasCold: uncachedTotal > 0,
                totalFrames: total,
                uncachedFrames: uncachedTotal,
                matches: sortedFrames.count,
                ocrRuns: ocrRuns,
                loadFailures: loadFailures
            )

            print(
                "[JustNow] Search complete: \(sortedFrames.count) matches, " +
                "\(cachedIDs.count) cache hits, \(ocrRuns) OCR runs, \(loadFailures) frame load failures"
            )

            let finalResults = sortedFrames
            let finalSelectedIndex = finalResults.isEmpty ? nil : finalResults.count - 1

            await MainActor.run {
                if !Task.isCancelled {
                    searchResults = finalResults
                    isSearchInProgress = false
                    if let finalSelectedIndex {
                        selectedIndex = finalSelectedIndex
                    }
                }
            }
        }
    }

    func moveLeft() {
        guard ensureDisplayedSelection() else { return }
        if selectedIndex > 0 {
            selectedIndex -= 1
        }
    }

    func moveRight() {
        guard ensureDisplayedSelection() else { return }
        if selectedIndex < displayedFrameCount - 1 {
            selectedIndex += 1
        }
    }

    func jumpLeft() {
        guard ensureDisplayedSelection() else { return }
        selectedIndex = max(0, selectedIndex - 10)
    }

    func jumpRight() {
        guard ensureDisplayedSelection() else { return }
        selectedIndex = min(displayedFrameCount - 1, selectedIndex + 10)
    }

    func goToStart() {
        guard ensureDisplayedSelection() else { return }
        selectedIndex = 0
    }

    func goToEnd() {
        guard ensureDisplayedSelection() else { return }
        selectedIndex = max(0, displayedFrameCount - 1)
    }

    func scrollBy(_ delta: CGFloat) {
        guard ensureDisplayedSelection() else { return }
        let step = delta > 0 ? -1 : 1
        let newIndex = selectedIndex + step
        selectedIndex = max(0, min(displayedFrameCount - 1, newIndex))
    }

    private func ensureDisplayedSelection() -> Bool {
        guard displayedFrameCount > 0 else {
            selectedIndex = 0
            return false
        }
        selectedIndex = max(0, min(displayedFrameCount - 1, selectedIndex))
        return true
    }
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
        .compatGlassEffect(cornerRadius: 20)
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
            } else if !viewModel.isSearching && viewModel.timelineFrames.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("No frames in this rewind window")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.6))
                    Text("Search can still look through the last hour.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.45))
                }
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
            }
            label: {
                Label("Clear search", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(SearchTimeScope.allCases, id: \.self) { scope in
                    Button {
                        viewModel.searchTimeScope = scope
                        if !viewModel.searchQuery.isEmpty {
                            viewModel.performSearch()
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
    }
}

struct InstructionsOverlay: View {
    var body: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 16) {
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

private struct TimelineSlider: View {
    var viewModel: OverlayViewModel

    private var displayedFrames: [StoredFrame] { viewModel.displayedFrames }
    private var frameCount: Int { displayedFrames.count }
    private var timelineMarkers: [TimelineMarker] {
        guard !(viewModel.isSearching && !viewModel.searchQuery.isEmpty) else { return [] }
        return timelineLandmarkMarkers(
            frames: displayedFrames,
            recentWindow: viewModel.recentTimelineWindow,
            now: viewModel.timelineReferenceDate
        )
    }

    private var colourSegments: [TimelineZoneFill] {
        guard !(viewModel.isSearching && !viewModel.searchQuery.isEmpty) else {
            return timelineColourSegments(frames: displayedFrames, borderPosition: nil)
        }

        let recentWindowPosition =
            timelineMarkers.first(where: { $0.targetAge == viewModel.recentTimelineWindow })?.position
            ?? resolveTimelineMarkerPosition(
                frames: displayedFrames,
                targetAge: viewModel.recentTimelineWindow,
                now: viewModel.timelineReferenceDate
            )
        return timelineColourSegments(
            frames: displayedFrames,
            borderPosition: recentWindowPosition
        )
    }

    private var currentFrame: StoredFrame? {
        displayedFrames[safe: viewModel.selectedIndex]
    }

    var body: some View {
        VStack(spacing: 12) {
            TimeLabels(frames: displayedFrames)

            SliderTrack(
                frameCount: frameCount,
                selectedIndex: viewModel.selectedIndex,
                markers: timelineMarkers,
                colourSegments: colourSegments,
                onIndexChanged: { viewModel.selectedIndex = $0 }
            )
            .frame(height: timelineMarkers.isEmpty ? 32 : 54)
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
                Text(framePositionLabel)
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

    private var framePositionLabel: String {
        guard frameCount > 0 else { return "0 / 0" }
        return "\(viewModel.selectedIndex + 1) / \(frameCount)"
    }
}

private struct TimeLabels: View {
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

private let timelineAbsoluteTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.timeStyle = .short
    formatter.dateStyle = .none
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

private struct SliderTrack: View {
    let frameCount: Int
    let selectedIndex: Int
    let markers: [TimelineMarker]
    let colourSegments: [TimelineZoneFill]
    let onIndexChanged: (Int) -> Void

    private let trackHeight: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let visibleMarkers = visibleMarkers(in: width)

            VStack(spacing: visibleMarkers.isEmpty ? 0 : 8) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous)
                        .fill(Color(red: 0.19, green: 0.19, blue: 0.21))
                        .frame(height: trackHeight)

                    if colourSegments.isEmpty {
                        RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                            .frame(height: trackHeight)
                    } else {
                        ZStack(alignment: .leading) {
                            ForEach(colourSegments) { fill in
                                if fill.start > 0 {
                                    RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous)
                                        .fill(fill.color.opacity(0.88))
                                        .frame(
                                            width: max(0, width - fill.start * width),
                                            height: trackHeight
                                        )
                                        .offset(x: fill.start * width)
                                } else {
                                    // Fill the full width; later segments paint over the right portion
                                    Rectangle()
                                        .fill(fill.color.opacity(0.88))
                                        .frame(height: trackHeight)
                                }
                            }
                        }
                        .frame(width: width, height: trackHeight)
                        .clipShape(RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous))

                        RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.05),
                                        Color.white.opacity(0.01)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: trackHeight)
                    }

                    if colourSegments.isEmpty {
                        RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous)
                            .fill(Color.white.opacity(0.55))
                            .frame(width: progressWidth(in: width), height: trackHeight)
                    }

                    if !visibleMarkers.isEmpty {
                        ForEach(visibleMarkers) { marker in
                            Rectangle()
                                .fill(marker.tint)
                                .frame(width: 3, height: trackHeight)
                                .offset(x: (width * marker.position) - 1.5)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous))
                    }

                    Circle()
                        .fill(.white)
                        .frame(width: 24, height: 24)
                        .shadow(color: .black.opacity(0.3), radius: 4)
                        .offset(x: thumbOffset(in: width))
                }
                .frame(height: 24)

                if !visibleMarkers.isEmpty {
                    ZStack(alignment: .leading) {
                        ForEach(labelPlacements(for: visibleMarkers, in: width)) { placement in
                            Text(placement.marker.label)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.45))
                                .fixedSize()
                                .position(x: placement.x, y: 6)
                        }
                    }
                    .frame(height: 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard frameCount > 0 else { return }
                        let percent = max(0, min(1, value.location.x / width))
                        let newIndex = Int(percent * CGFloat(frameCount - 1))
                        onIndexChanged(newIndex)
                    }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline")
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                adjustSelection(by: 1)
            case .decrement:
                adjustSelection(by: -1)
            @unknown default:
                break
            }
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

    private func visibleMarkers(in width: CGFloat) -> [TimelineMarker] {
        let inset: CGFloat = 34
        let minimumSpacing: CGFloat = 56
        let basePlacements = markers.map { marker in
            let x = min(max(width * marker.position, inset), max(inset, width - inset))
            return TimelineLabelPlacement(marker: marker, x: x)
        }

        guard basePlacements.count > 1 else { return basePlacements.map(\.marker) }

        var kept: [TimelineLabelPlacement] = []
        let prioritized = basePlacements.sorted { lhs, rhs in
            if lhs.marker.priority != rhs.marker.priority {
                return lhs.marker.priority < rhs.marker.priority
            }
            if lhs.marker.targetAge != rhs.marker.targetAge {
                return lhs.marker.targetAge < rhs.marker.targetAge
            }
            return lhs.marker.position > rhs.marker.position
        }

        for candidate in prioritized {
            let overlapsExisting = kept.contains { abs($0.x - candidate.x) < minimumSpacing }
            if !overlapsExisting {
                kept.append(candidate)
            }
        }

        return kept
            .map(\.marker)
            .sorted { $0.position < $1.position }
    }

    private func labelPlacements(for markers: [TimelineMarker], in width: CGFloat) -> [TimelineLabelPlacement] {
        let inset: CGFloat = 34

        return markers.map { marker in
            let x = min(max(width * marker.position, inset), max(inset, width - inset))
            return TimelineLabelPlacement(marker: marker, x: x)
        }
    }

    private var accessibilityValue: String {
        guard frameCount > 0 else { return "No frames" }
        return "Frame \(selectedIndex + 1) of \(frameCount)"
    }

    private func adjustSelection(by delta: Int) {
        guard frameCount > 0 else { return }
        let nextIndex = max(0, min(frameCount - 1, selectedIndex + delta))
        guard nextIndex != selectedIndex else { return }
        onIndexChanged(nextIndex)
    }
}

private struct TimelineMarker: Identifiable {
    let targetAge: TimeInterval
    let targetDate: Date
    let label: String
    let position: CGFloat
    let frameIndex: Int
    let priority: Int
    let tint: Color = Color(red: 1.0, green: 0.86, blue: 0.12)

    var id: Int { frameIndex }
}

private struct TimelineMarkerTarget: Identifiable {
    let targetAge: TimeInterval
    let targetDate: Date
    let label: String
    let priority: Int

    var id: String { "\(priority)-\(targetDate.timeIntervalSinceReferenceDate)" }
}

private struct TimelineZoneFill: Identifiable {
    let start: CGFloat
    let end: CGFloat
    let color: Color

    var id: String { "\(start)-\(end)" }
}

private struct TimelineLabelPlacement: Identifiable {
    let marker: TimelineMarker
    var x: CGFloat

    var id: Int { marker.id }
}

private func resolveTimelineMarkerFrameIndex(
    frames: [StoredFrame],
    targetDate: Date
) -> Int? {
    guard frames.count > 1 else { return nil }

    let olderIndex = frames.lastIndex(where: { $0.timestamp <= targetDate })
    let newerIndex = frames.firstIndex(where: { $0.timestamp >= targetDate })

    switch (olderIndex, newerIndex) {
    case let (.some(older), .some(newer)):
        let olderDistance = abs(frames[older].timestamp.timeIntervalSince(targetDate))
        let newerDistance = abs(frames[newer].timestamp.timeIntervalSince(targetDate))
        return olderDistance <= newerDistance ? older : newer
    case let (.some(older), nil):
        return older
    case let (nil, .some(newer)):
        return newer
    case (nil, nil):
        return nil
    }
}

private func resolveTimelineMarkerPosition(
    frames: [StoredFrame],
    targetAge: TimeInterval,
    now: Date = Date()
) -> CGFloat? {
    guard frames.count > 1 else { return nil }

    let targetDate = now.addingTimeInterval(-targetAge)
    guard let frameIndex = resolveTimelineMarkerFrameIndex(
        frames: frames,
        targetDate: targetDate
    ) else { return nil }

    return CGFloat(frameIndex) / CGFloat(frames.count - 1)
}

private func timelineLandmarkMarkers(
    frames: [StoredFrame],
    recentWindow: TimeInterval,
    now: Date = Date()
) -> [TimelineMarker] {
    guard frames.count > 1, let oldest = frames.first?.timestamp else { return [] }

    let oldestAge = now.timeIntervalSince(oldest)
    let targets = timelineMarkerTargets(
        upTo: oldestAge,
        recentWindow: recentWindow,
        now: now
    )
    var markersByFrameIndex: [Int: TimelineMarker] = [:]

    for target in targets {
        guard let frameIndex = resolveTimelineMarkerFrameIndex(
            frames: frames,
            targetDate: target.targetDate
        ) else { continue }

        let frame = frames[frameIndex]
        guard isTimelineMarkerRepresentative(
            targetAge: target.targetAge,
            targetDate: target.targetDate,
            frameDate: frame.timestamp
        ) else { continue }

        let position = CGFloat(frameIndex) / CGFloat(frames.count - 1)
        let marker = TimelineMarker(
            targetAge: target.targetAge,
            targetDate: target.targetDate,
            label: target.label,
            position: position,
            frameIndex: frameIndex,
            priority: target.priority
        )

        if let existing = markersByFrameIndex[frameIndex] {
            markersByFrameIndex[frameIndex] = existing.priority <= marker.priority ? existing : marker
        } else {
            markersByFrameIndex[frameIndex] = marker
        }
    }

    return markersByFrameIndex.values.sorted { $0.position < $1.position }
}

private func timelineMarkerTargets(
    upTo oldestAge: TimeInterval,
    recentWindow: TimeInterval,
    now: Date
) -> [TimelineMarkerTarget] {
    guard oldestAge > 0 else { return [] }

    let markerAges = [5.0 * 60, 10.0 * 60, 30.0 * 60, 60.0 * 60, 2.0 * 60.0 * 60.0]
    let preferredAges = ([recentWindow] + markerAges)
        .filter { $0 <= oldestAge }

    var seenAges: Set<Int> = []
    let relativeAges = preferredAges.filter { seenAges.insert(Int($0)).inserted }
    var targets = relativeAges.enumerated().map { index, targetAge in
        TimelineMarkerTarget(
            targetAge: targetAge,
            targetDate: now.addingTimeInterval(-targetAge),
            label: formatTimelineMarkerLabel(targetAge: targetAge, targetDate: now.addingTimeInterval(-targetAge)),
            priority: index
        )
    }

    if oldestAge > 2 * 60 * 60 {
        let blockHours = [3, 4, 6, 8, 12, 16, 24]
        var priority = targets.count
        var seenDates: Set<TimeInterval> = Set(targets.map { $0.targetDate.timeIntervalSinceReferenceDate })
        for blockHour in blockHours {
            guard blockHour <= Int(oldestAge / 3600) else { continue }
            let rawTargetDate = now.addingTimeInterval(-TimeInterval(blockHour * 3600))
            let snappedTargetDate = snappedTimelineAbsoluteDate(rawTargetDate)
            let snappedAge = now.timeIntervalSince(snappedTargetDate)

            if snappedAge > 2 * 60 * 60,
               snappedAge <= oldestAge,
               seenDates.insert(snappedTargetDate.timeIntervalSinceReferenceDate).inserted {
                targets.append(
                    TimelineMarkerTarget(
                        targetAge: snappedAge,
                        targetDate: snappedTargetDate,
                        label: formatTimelineMarkerLabel(targetAge: snappedAge, targetDate: snappedTargetDate),
                        priority: priority
                    )
                )
                priority += 1
            }
        }
    }

    return targets
}

private func snappedTimelineAbsoluteDate(_ date: Date) -> Date {
    let interval = date.timeIntervalSinceReferenceDate
    let halfHour: TimeInterval = 30 * 60
    let snapped = (interval / halfHour).rounded() * halfHour
    return Date(timeIntervalSinceReferenceDate: snapped)
}

private func isTimelineMarkerRepresentative(
    targetAge: TimeInterval,
    targetDate: Date,
    frameDate: Date
) -> Bool {
    let tolerance: TimeInterval

    if targetAge < 15 * 60 {
        tolerance = 5 * 60
    } else if targetAge < 45 * 60 {
        tolerance = 15 * 60
    } else if targetAge < 2 * 60 * 60 {
        tolerance = 30 * 60
    } else {
        tolerance = 90 * 60
    }

    return abs(frameDate.timeIntervalSince(targetDate)) <= tolerance
}

private func timelineColourSegments(
    frames: [StoredFrame],
    borderPosition: CGFloat?
) -> [TimelineZoneFill] {
    guard frames.count > 1 else { return [] }

    // Darker grey on left (oldest), lighter grey on right (newest/recent)
    let olderColor = Color(red: 0.30, green: 0.28, blue: 0.31)
    let newerColor = Color(red: 0.55, green: 0.52, blue: 0.56)

    var segments: [TimelineZoneFill] = []

    if let borderPosition, borderPosition > 0 {
        segments.append(
            TimelineZoneFill(
                start: 0,
                end: borderPosition,
                color: olderColor
            )
        )
        segments.append(
            TimelineZoneFill(
                start: borderPosition,
                end: 1,
                color: newerColor
            )
        )
    } else {
        segments.append(
            TimelineZoneFill(
                start: 0,
                end: 1,
                color: newerColor
            )
        )
    }

    return segments.filter { $0.end > $0.start }
}

private func formatTimelineMarkerLabel(targetAge: TimeInterval, targetDate: Date) -> String {
    if targetAge < 60 * 60 {
        let totalMinutes = Int(targetAge / 60)
        return "\(totalMinutes)min"
    }

    if targetAge <= 2 * 60 * 60 {
        let totalHours = Int(targetAge / 3600)
        return "\(totalHours)h"
    }

    return timelineAbsoluteTimeFormatter.string(from: targetDate)
}
