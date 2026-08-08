//
//  OverlayViewModel.swift
//  JustNow
//

import AppKit
import CoreGraphics
import Foundation
import Observation
import SwiftUI
import os.log

private let overlayViewLogger = Logger(subsystem: "sg.tk.JustNow", category: "OverlayView")

enum OverlayToastStyle: Equatable {
    case success
    case error
    case info
}

struct OverlayToast: Equatable, Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String?
    let style: OverlayToastStyle
    let revealURL: URL?

    var isError: Bool { style == .error }
}

enum SearchTimeScope: String, CaseIterable {
    case fiveMinutes
    case oneHour
    case rewindHistory
    case all

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

nonisolated struct TimelineSelection: Equatable {
    let spanID: UUID
    let timestamp: Date
    let entryIndex: Int
}

nonisolated struct OverlayFrameExportSelection: Equatable {
    let frame: StoredFrame
    let timestamp: Date
}

/// Resolve a real point in time to a logical span.
///
/// Inside coverage, the requested timestamp is preserved. In a gap the nearest
/// endpoint wins; an exact distance tie picks the older endpoint. Equal
/// boundaries and overlapping coverage pick the later durable entry.
nonisolated func resolveTimelineSelection(
    entries: [TimelineEntry],
    target: Date
) -> TimelineSelection? {
    guard !entries.isEmpty else { return nil }

    if let containingIndex = entries.indices.reversed().first(where: { index in
        let bounds = timelineSpanBounds(for: entries[index])
        return bounds.start <= target && target <= bounds.end
    }) {
        return TimelineSelection(
            spanID: entries[containingIndex].span.id,
            timestamp: target,
            entryIndex: containingIndex
        )
    }

    struct Endpoint {
        let date: Date
        let entryIndex: Int
    }

    var best: Endpoint?
    var bestDistance = TimeInterval.greatestFiniteMagnitude
    for index in entries.indices {
        let bounds = timelineSpanBounds(for: entries[index])
        for date in [bounds.start, bounds.end] {
            let distance = abs(date.timeIntervalSince(target))
            if distance < bestDistance {
                best = Endpoint(date: date, entryIndex: index)
                bestDistance = distance
            } else if distance == bestDistance, let current = best {
                if date < current.date || (date == current.date && index > current.entryIndex) {
                    best = Endpoint(date: date, entryIndex: index)
                }
            }
        }
    }

    guard let best else { return nil }
    return TimelineSelection(
        spanID: entries[best.entryIndex].span.id,
        timestamp: best.date,
        entryIndex: best.entryIndex
    )
}

nonisolated func clampedTimelineReferenceDate(
    requested: Date,
    entries: [TimelineEntry]
) -> Date {
    entries.reduce(requested) { partial, entry in
        max(partial, timelineSpanBounds(for: entry).end)
    }
}

nonisolated func latestTimelineSelection(in entries: [TimelineEntry]) -> TimelineSelection? {
    guard let latestObservation = entries.map({ timelineSpanBounds(for: $0).end }).max() else {
        return nil
    }
    return resolveTimelineSelection(entries: entries, target: latestObservation)
}

nonisolated func adjacentTimelineSelection(
    in entries: [TimelineEntry],
    excludingSpanID: UUID?,
    from timestamp: Date,
    rewinding: Bool
) -> TimelineSelection? {
    var best: TimelineSelection?

    for (index, entry) in entries.enumerated() where entry.span.id != excludingSpanID {
        let bounds = timelineSpanBounds(for: entry)
        let endpoints = [bounds.start, bounds.end]
        let candidateTimestamp: Date?
        if rewinding {
            candidateTimestamp = endpoints.filter { $0 < timestamp }.max()
        } else {
            candidateTimestamp = endpoints.filter { $0 > timestamp }.min()
        }
        guard let candidateTimestamp else { continue }

        let candidate = TimelineSelection(
            spanID: entry.span.id,
            timestamp: candidateTimestamp,
            entryIndex: index
        )
        guard let currentBest = best else {
            best = candidate
            continue
        }

        let isCloser = rewinding
            ? candidate.timestamp > currentBest.timestamp
            : candidate.timestamp < currentBest.timestamp
        if isCloser
            || (candidate.timestamp == currentBest.timestamp
                && candidate.entryIndex > currentBest.entryIndex) {
            best = candidate
        }
    }

    return best
}

nonisolated func preservingTimelineSelection(
    in entries: [TimelineEntry],
    preferredSpanID: UUID?,
    target: Date,
    preferLatestWhenMissing: Bool
) -> TimelineSelection? {
    if let preferredSpanID,
       let index = entries.firstIndex(where: { $0.span.id == preferredSpanID }) {
        let bounds = timelineSpanBounds(for: entries[index])
        return TimelineSelection(
            spanID: preferredSpanID,
            timestamp: min(max(target, bounds.start), bounds.end),
            entryIndex: index
        )
    }
    if preferLatestWhenMissing {
        return latestTimelineSelection(in: entries)
    }
    return resolveTimelineSelection(entries: entries, target: target)
}

nonisolated func timelinePrefetchFrames(
    entries: [TimelineEntry],
    selectedIndex: Int,
    radius: Int
) -> [StoredFrame] {
    guard entries.indices.contains(selectedIndex), radius > 0 else { return [] }
    let lowerBound = max(0, selectedIndex - radius)
    let upperBound = min(entries.count - 1, selectedIndex + radius)
    var seenFrameIDs: Set<UUID> = [entries[selectedIndex].frame.id]
    return (lowerBound...upperBound).compactMap { index in
        guard index != selectedIndex else { return nil }
        let frame = entries[index].frame
        return seenFrameIDs.insert(frame.id).inserted ? frame : nil
    }
}

nonisolated func timelinePrefetchProjectionKey(
    entries: [TimelineEntry],
    selectedSpanID: UUID?,
    radius: Int
) -> String {
    guard let selectedSpanID,
          let selectedIndex = entries.firstIndex(where: { $0.span.id == selectedSpanID }) else {
        return "none|\(entries.count)"
    }
    let lowerBound = max(0, selectedIndex - max(0, radius))
    let upperBound = min(entries.count - 1, selectedIndex + max(0, radius))
    let projection = entries[lowerBound...upperBound].map { entry in
        "\(entry.span.id.uuidString):\(entry.frame.id.uuidString)"
    }
    return "\(selectedSpanID.uuidString)|\(entries.count)|\(projection.joined(separator: ","))"
}

@Observable
@MainActor
class OverlayViewModel {
    private struct SearchRequest: Equatable {
        let query: String
        let scope: SearchTimeScope
    }

    private static let searchDebounceDelay: Duration = .milliseconds(220)
    private static let fullImagePrefetchRadius = 3

    private(set) var selectedTimestamp: Date
    private(set) var selectedSpanID: UUID?
    var presentedFrame: StoredFrame?
    private(set) var timelineEntries: [TimelineEntry]
    /// Full repository snapshot protected by the overlay's payload lease.
    /// Display switching and search are projections of this immutable set.
    private let leasedTimelineEntries: [TimelineEntry]
    let frameBuffer: FrameBuffer
    let recentTimelineWindow: TimeInterval
    let rewindHistoryOption: RewindHistoryOption
    /// Immutable wall-clock snapshot used for retention and search semantics.
    let semanticReferenceDate: Date
    /// Drawable range end, clamped forward only so future/rollback spans remain visible.
    private(set) var timelineReferenceDate: Date
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void
    let availableDisplays: [DisplayInfo]
    private(set) var activeDisplay: DisplayInfo?
    private let primaryDisplayID: UUID?

    var isSearching = false
    var searchQuery = ""
    var searchTimeScope: SearchTimeScope = .all
    var searchResults: [TimelineEntry] = []
    var isSearchPending = false
    var isSearchInProgress = false
    var searchIndexStatus: SearchIndexStatus = .empty
    private var searchDebounceTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var imagePrefetchTask: Task<Void, Never>?
    private var resolvedSearchRequest: SearchRequest?
    var isTextGrabActive = false
    private var cancelTextGrabHandler: (() -> Void)?

    var saveToast: OverlayToast?
    private var saveToastTask: Task<Void, Never>?
    private var screenshotSaveTasks: [UUID: Task<Void, Never>] = [:]
    private var acceptsScreenshotSaves = true

    /// Tracks whether ⌘ is currently held inside the overlay window. The
    /// modifier-flag monitor in OverlayWindowController writes here so the
    /// instructions pill and selection drag handler can switch between the
    /// user's default drag action and the alternate action.
    var isCommandHeld: Bool = false

    /// Set true by the "Save Region…" menu item so the very next drag
    /// performs a region screenshot regardless of the user's default drag
    /// action. The drag handler clears it after consuming, so this is one-shot.
    var isRegionScreenshotArmed: Bool = false

    var isSearchAvailable: Bool {
        true
    }

    var hasSearchQuery: Bool {
        !normalisedSearchQuery.isEmpty
    }

    var isSearchLoading: Bool {
        isSearchPending || isSearchInProgress
    }

    var shouldShowSearchingState: Bool {
        isSearchAvailable && isSearching && hasSearchQuery && isSearchLoading
    }

    var shouldShowNoSearchResults: Bool {
        isSearchAvailable
            && isSearching
            && hasSearchQuery
            && !isSearchLoading
            && resolvedSearchRequest == currentSearchRequest
            && searchResults.isEmpty
    }

    var selectedIndex: Int {
        get {
            guard let selectedSpanID,
                  let index = displayedEntries.firstIndex(where: { $0.span.id == selectedSpanID }) else {
                return 0
            }
            return index
        }
        set {
            guard let entry = displayedEntries[safe: newValue] else { return }
            let bounds = timelineSpanBounds(for: entry)
            let timestamp = min(max(selectedTimestamp, bounds.start), bounds.end)
            select(spanID: entry.span.id, timestamp: timestamp)
        }
    }

    var selectedFramePrefetchKey: String {
        timelinePrefetchProjectionKey(
            entries: displayedEntries,
            selectedSpanID: selectedSpanID,
            radius: Self.fullImagePrefetchRadius
        )
    }

    var displayedEntries: [TimelineEntry] {
        isSearchAvailable && isSearching && hasSearchQuery ? searchResults : timelineEntries
    }

    /// Compatibility projection for image consumers. Logical identity and
    /// geometry always come from `displayedEntries`.
    var displayedFrames: [StoredFrame] {
        displayedEntries.map(\.frame)
    }

    var timelineFrames: [StoredFrame] {
        timelineEntries.map(\.frame)
    }

    var displayedFrameCount: Int {
        displayedFrames.count
    }

    var canMoveLeft: Bool {
        displayedFrameCount > 0 && selectedIndex > 0
    }

    var canMoveRight: Bool {
        displayedFrameCount > 0 && selectedIndex < displayedFrameCount - 1
    }

    var currentEntry: TimelineEntry? {
        guard let selectedSpanID else { return nil }
        return displayedEntries.first { $0.span.id == selectedSpanID }
    }

    var currentFrame: StoredFrame? {
        currentEntry?.frame
    }

    var currentExportSelection: OverlayFrameExportSelection? {
        currentFrame.map { OverlayFrameExportSelection(frame: $0, timestamp: selectedTimestamp) }
    }

    var timelineStartDate: Date? {
        displayedEntries.map { timelineSpanBounds(for: $0).start }.min()
    }

    var accessibilityTimelineValue: String {
        guard currentEntry != nil else { return "No timeline spans" }
        let ordinal = selectedIndex + 1
        let relative = formatRelativeTime(selectedTimestamp, now: timelineReferenceDate)
        let selectedTime = selectedTimestamp.formatted(date: .abbreviated, time: .standard)
        return "Span \(ordinal) of \(displayedFrameCount), \(relative), selected time \(selectedTime)"
    }

    var hasRetainedFrames: Bool {
        frameBuffer.frameCount > 0
    }

    var hasAnyFrames: Bool {
        !timelineEntries.isEmpty || hasRetainedFrames
    }

    init(
        timelineEntries: [TimelineEntry],
        leasedTimelineEntries: [TimelineEntry]? = nil,
        frameBuffer: FrameBuffer,
        recentTimelineWindow: TimeInterval,
        rewindHistoryOption: RewindHistoryOption,
        availableDisplays: [DisplayInfo],
        activeDisplay: DisplayInfo?,
        primaryDisplayID: UUID?,
        timelineReferenceDate: Date = Date(),
        onDismiss: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.timelineEntries = timelineEntries
        self.leasedTimelineEntries = leasedTimelineEntries ?? frameBuffer.getTimelineEntries()
        self.frameBuffer = frameBuffer
        self.recentTimelineWindow = recentTimelineWindow
        self.rewindHistoryOption = rewindHistoryOption
        self.semanticReferenceDate = timelineReferenceDate
        let resolvedReferenceDate = clampedTimelineReferenceDate(
            requested: timelineReferenceDate,
            entries: timelineEntries
        )
        self.timelineReferenceDate = resolvedReferenceDate
        self.availableDisplays = availableDisplays
        self.activeDisplay = activeDisplay
        self.primaryDisplayID = primaryDisplayID
        self.onDismiss = onDismiss
        self.onOpenSettings = onOpenSettings
        if let latest = latestTimelineSelection(in: timelineEntries) {
            self.selectedTimestamp = latest.timestamp
            self.selectedSpanID = latest.spanID
        } else {
            self.selectedTimestamp = resolvedReferenceDate
            self.selectedSpanID = nil
        }
    }

    func toggleSearch() {
        guard isSearchAvailable else {
            clearSearch()
            return
        }
        isSearching.toggle()
        if !isSearching {
            clearSearch()
        }
    }

    func clearSearch() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        searchTask?.cancel()
        searchTask = nil
        imagePrefetchTask?.cancel()
        imagePrefetchTask = nil
        isSearching = false
        searchQuery = ""
        searchResults = []
        isSearchPending = false
        isSearchInProgress = false
        resolvedSearchRequest = nil
        selectLatest(in: timelineEntries)
    }

    func setTextGrabCancellationHandler(_ handler: (() -> Void)?) {
        cancelTextGrabHandler = handler
    }

    @discardableResult
    func cancelTextGrabIfNeeded() -> Bool {
        guard isTextGrabActive else { return false }
        cancelTextGrabHandler?()
        return true
    }

    func refreshIndexStatus() async {
        let previousIndexedFrames = searchIndexStatus.indexedFrames
        let status = await frameBuffer.searchIndexStatus()
        searchIndexStatus = status

        guard isSearchAvailable, isSearching, hasSearchQuery else { return }
        guard !isSearchLoading else { return }
        guard status.indexedFrames != previousIndexedFrames else { return }

        performSearch(immediately: true)
    }

    func performSearch(immediately: Bool = false) {
        guard isSearchAvailable, isSearching else { return }

        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        searchTask?.cancel()
        searchTask = nil

        guard let request = currentSearchRequest else {
            searchResults = []
            isSearchPending = false
            isSearchInProgress = false
            resolvedSearchRequest = nil
            reconcileSelection(in: displayedEntries, preferLatestWhenMissing: true)
            return
        }

        resolvedSearchRequest = nil

        if immediately {
            beginSearch(for: request)
            return
        }

        isSearchPending = true
        isSearchInProgress = false

        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDebounceDelay)
            guard !Task.isCancelled else { return }

            self?.resumeDebouncedSearch(for: request)
        }
    }

    func moveLeft() {
        guard ensureDisplayedSelection() else { return }
        let previousIndex = selectedIndex - 1
        guard let entry = displayedEntries[safe: previousIndex] else { return }
        select(spanID: entry.span.id, timestamp: timelineSpanBounds(for: entry).end)
    }

    func moveRight() {
        guard ensureDisplayedSelection() else { return }
        let nextIndex = selectedIndex + 1
        guard let entry = displayedEntries[safe: nextIndex] else { return }
        select(spanID: entry.span.id, timestamp: timelineSpanBounds(for: entry).start)
    }

    func jumpLeft() {
        guard ensureDisplayedSelection() else { return }
        setSelectedTimestamp(selectedTimestamp.addingTimeInterval(-10))
    }

    func jumpRight() {
        guard ensureDisplayedSelection() else { return }
        setSelectedTimestamp(selectedTimestamp.addingTimeInterval(10))
    }

    func goToStart() {
        guard let oldestIndex = displayedEntries.indices.min(by: {
            timelineSpanBounds(for: displayedEntries[$0]).start
                < timelineSpanBounds(for: displayedEntries[$1]).start
        }) else { return }
        let oldest = displayedEntries[oldestIndex]
        select(spanID: oldest.span.id, timestamp: timelineSpanBounds(for: oldest).start)
    }

    func goToEnd() {
        selectLatest(in: displayedEntries)
    }

    func cycleDisplay(forward: Bool) {
        guard availableDisplays.count > 1 else { return }
        let activeID = activeDisplay?.id
        let currentIndex = availableDisplays.firstIndex { $0.id == activeID } ?? 0
        let step = forward ? 1 : -1
        let count = availableDisplays.count
        let nextIndex = ((currentIndex + step) % count + count) % count
        switchDisplay(to: availableDisplays[nextIndex])
    }

    func switchDisplay(to display: DisplayInfo) {
        guard display.id != activeDisplay?.id else { return }
        let newEntries = frameBuffer.filteredTimelineEntries(
            from: leasedTimelineEntries,
            recentWindow: recentTimelineWindow,
            maximumAge: rewindHistoryOption.duration,
            displayID: display.id,
            includeLegacyFrames: display.id == primaryDisplayID,
            now: semanticReferenceDate
        )
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            clearSearch()
            activeDisplay = display
            timelineEntries = newEntries
            timelineReferenceDate = clampedTimelineReferenceDate(
                requested: semanticReferenceDate,
                entries: newEntries
            )
            selectLatest(in: newEntries)
            presentedFrame = nil
        }
    }

    func prefetchImagesNearSelection() {
        imagePrefetchTask?.cancel()
        imagePrefetchTask = nil

        guard ensureDisplayedSelection() else { return }

        let framesToPrefetch = timelinePrefetchFrames(
            entries: displayedEntries,
            selectedIndex: selectedIndex,
            radius: Self.fullImagePrefetchRadius
        )
        guard !framesToPrefetch.isEmpty else { return }

        let buffer = frameBuffer
        imagePrefetchTask = Task(priority: .utility) {
            await buffer.prefetchFullImages(for: framesToPrefetch)
        }
    }

    func scrollBy(_ delta: CGFloat) {
        guard delta.isFinite, delta != 0 else { return }
        guard ensureDisplayedSelection() else { return }

        // Scrolling navigates logical timeline entries rather than elapsed
        // seconds. Hybrid history is deliberately sparse on disk, so moving a
        // second at a time can repeatedly resolve to the same real endpoint
        // and appear to stop. Entry navigation always makes visible progress
        // when an older or newer item exists.
        guard let selection = adjacentTimelineSelection(
                  in: displayedEntries,
                  excludingSpanID: selectedSpanID,
                  from: selectedTimestamp,
                  rewinding: delta > 0
              ) else { return }
        select(spanID: selection.spanID, timestamp: selection.timestamp)
    }

    var canSaveCurrentFrame: Bool {
        currentFrame != nil
    }

    func openSettings() {
        onDismiss()
        onOpenSettings()
    }

    func saveCurrentFrameToScreenshotsLocation() {
        guard let exportSelection = currentExportSelection else { return }
        let buffer = frameBuffer
        performScreenshotSave(operationName: "current frame") { destinations in
            var savedURL: URL? = nil
            if destinations.toFolder {
                savedURL = try await buffer.saveFrameToScreenshotsLocation(
                    exportSelection.frame,
                    timestamp: exportSelection.timestamp
                )
            }
            if destinations.toClipboard {
                let image = try await buffer.getFullImage(for: exportSelection.frame)
                Self.copyImageToClipboard(image)
            }
            return savedURL
        }
    }

    /// Save a region cropped from the displayed frame. Called by the
    /// drag-to-region path when ⌘ is held during the drag.
    func saveCroppedScreenshot(image: CGImage) {
        let logicalTimestamp = selectedTimestamp
        let buffer = frameBuffer
        performScreenshotSave(operationName: "cropped region") { destinations in
            var savedURL: URL? = nil
            if destinations.toFolder {
                savedURL = try await buffer.saveCroppedImageToScreenshotsLocation(
                    image,
                    timestamp: logicalTimestamp
                )
            }
            if destinations.toClipboard {
                Self.copyImageToClipboard(image)
            }
            return savedURL
        }
    }

    private func performScreenshotSave(
        operationName: String,
        operation: @escaping (_ destinations: SaveDestinations) async throws -> URL?
    ) {
        guard acceptsScreenshotSaves else { return }
        let destinations = currentSaveDestinations()
        let operationID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { screenshotSaveTasks[operationID] = nil }
            do {
                let savedURL = try await operation(destinations)
                playSavedSoundIfNeeded()
                showSaveToast(makeSuccessToast(savedURL: savedURL, destinations: destinations))
                markQualityInfoPendingIfNeeded()
            } catch {
                overlayViewLogger.error(
                    "Failed screenshot save (\(operationName, privacy: .public)): \(error.localizedDescription, privacy: .private)"
                )
                showSaveToast(makeErrorToast(error))
            }
        }
        screenshotSaveTasks[operationID] = task
    }

    /// Prevents new save work from starting once overlay teardown begins.
    /// The controller keeps the overlay payload lease alive until
    /// `waitForPendingScreenshotSaves()` returns, so a suspended export cannot
    /// lose its volatile JPEG to dismissal or memory-pressure trimming.
    func prepareForDismissal() {
        acceptsScreenshotSaves = false
        clearSearch()
    }

    func waitForPendingScreenshotSaves() async {
        let tasks = Array(screenshotSaveTasks.values)
        for task in tasks {
            await task.value
        }
    }

    private struct SaveDestinations {
        var toFolder: Bool
        var toClipboard: Bool
    }

    /// Resolve the user's chosen save destinations. If both toggles end up
    /// off (which the Settings UI prevents but UserDefaults could still
    /// reach via direct edits), force folder back on so a save attempt is
    /// never silently dropped.
    private func currentSaveDestinations() -> SaveDestinations {
        let defaults = UserDefaults.standard
        let toFolder = defaults.object(forKey: AppStorageKey.screenshotSaveToFolder) as? Bool
            ?? AppStorageDefault.screenshotSaveToFolder
        let toClipboard = defaults.object(forKey: AppStorageKey.screenshotSaveToClipboard) as? Bool
            ?? AppStorageDefault.screenshotSaveToClipboard
        if !toFolder && !toClipboard {
            return SaveDestinations(toFolder: true, toClipboard: false)
        }
        return SaveDestinations(toFolder: toFolder, toClipboard: toClipboard)
    }

    private static func copyImageToClipboard(_ image: CGImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        pasteboard.writeObjects([nsImage])
    }

    private func makeSuccessToast(savedURL: URL?, destinations: SaveDestinations) -> OverlayToast {
        let title: String
        let detail: String?
        let revealURL: URL?

        if destinations.toFolder && destinations.toClipboard, let savedURL {
            title = "Saved & copied"
            detail = savedURL.lastPathComponent
            revealURL = savedURL
        } else if destinations.toFolder, let savedURL {
            title = savedToastTitle(for: savedURL)
            detail = savedURL.lastPathComponent
            revealURL = savedURL
        } else if destinations.toClipboard {
            title = "Copied to clipboard"
            detail = nil
            revealURL = nil
        } else {
            title = "Saved"
            detail = nil
            revealURL = nil
        }

        return OverlayToast(
            icon: "checkmark.circle.fill",
            title: title,
            detail: detail,
            style: .success,
            revealURL: revealURL
        )
    }

    private func makeErrorToast(_ error: Error) -> OverlayToast {
        OverlayToast(
            icon: "exclamationmark.triangle.fill",
            title: "Couldn\u{2019}t save screenshot",
            detail: error.localizedDescription,
            style: .error,
            revealURL: nil
        )
    }

    /// Show a transient instructional banner in the toast slot. Used by
    /// region-arming so the user knows what to do next.
    func showInfoToast(icon: String, title: String, dismissAfter: TimeInterval = 4) {
        let toast = OverlayToast(
            icon: icon,
            title: title,
            detail: nil,
            style: .info,
            revealURL: nil
        )
        saveToastTask?.cancel()
        saveToast = toast
        saveToastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(dismissAfter))
            guard !Task.isCancelled else { return }
            saveToast = nil
        }
    }

    /// Triggered by the "Save Region…" menu item: the next drag captures a region
    /// screenshot regardless of the user's default drag action.
    func armRegionScreenshot() {
        isRegionScreenshotArmed = true
        let defaults = UserDefaults.standard
        let hintCount = defaults.integer(forKey: AppStorageKey.regionScreenshotShortcutHintCount)
        let title: String
        if hintCount < 2 {
            title = "Drag to capture a screenshot region."
            defaults.set(hintCount + 1, forKey: AppStorageKey.regionScreenshotShortcutHintCount)
        } else {
            title = "Drag to capture."
        }
        showInfoToast(
            icon: "rectangle.dashed",
            title: title
        )
    }

    func disarmRegionScreenshot() {
        isRegionScreenshotArmed = false
    }

    /// Toast title for a successful save. Prefers "Saved to <FolderName>"
    /// when the folder name is short and looks like a normal directory name;
    /// falls back to plain "Saved" so we never overflow the toast width.
    private func savedToastTitle(for url: URL) -> String {
        let folderName = url.deletingLastPathComponent().lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-_."))
        let isFriendly =
            !folderName.isEmpty
            && folderName.count <= 14
            && folderName.unicodeScalars.allSatisfy { allowed.contains($0) }
        return isFriendly ? "Saved to \(folderName)" : "Saved"
    }

    private func showSaveToast(_ toast: OverlayToast) {
        saveToastTask?.cancel()
        saveToast = toast
        saveToastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(toast.isError ? 4 : 2.5))
            guard !Task.isCancelled else { return }
            saveToast = nil
        }
    }

    func revealSavedFile(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
        deferQualityInfoUntilLaterIfPending()
        onDismiss()
    }

    /// Set true on the first successful save when the user hasn't yet seen
    /// the quality info. The window controller reads and clears this on
    /// hideOverlay so the NSAlert can present *after* the overlay window
    /// has gone — avoiding the z-order trap (overlay sits at .statusBar+1
    /// while NSAlert defaults to .modalPanel) and the keyDown monitor
    /// stealing the alert's Enter.
    var shouldShowQualityInfoOnDismiss: Bool = false

    /// Mark that the quality alert should fire after this overlay session
    /// closes. Idempotent: a second mark in the same session is harmless.
    /// Setting hasSeen here (not after the alert dismisses) keeps a forced
    /// quit between save and overlay-close from re-prompting next time.
    private func markQualityInfoPendingIfNeeded() {
        let defaults = UserDefaults.standard
        let hasSeen = defaults.bool(forKey: AppStorageKey.hasSeenSaveQualityInfo)
        guard !hasSeen else { return }
        defaults.set(true, forKey: AppStorageKey.hasSeenSaveQualityInfo)
        shouldShowQualityInfoOnDismiss = true
    }

    private func deferQualityInfoUntilLaterIfPending() {
        guard shouldShowQualityInfoOnDismiss else { return }
        shouldShowQualityInfoOnDismiss = false
        UserDefaults.standard.set(false, forKey: AppStorageKey.hasSeenSaveQualityInfo)
    }

    private func playSavedSoundIfNeeded() {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: AppStorageKey.saveScreenshotSoundEnabled) as? Bool
            ?? AppStorageDefault.saveScreenshotSoundEnabled
        guard enabled else { return }
        ScreenshotSound.play()
    }

    func setPresentedFrame(_ frame: StoredFrame?) {
        guard presentedFrame?.id != frame?.id else { return }
        presentedFrame = frame
    }

    private var normalisedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentSearchRequest: SearchRequest? {
        guard hasSearchQuery else { return nil }
        return SearchRequest(query: normalisedSearchQuery, scope: searchTimeScope)
    }

    private func resumeDebouncedSearch(for request: SearchRequest) {
        guard isSearching else { return }
        guard currentSearchRequest == request else { return }
        beginSearch(for: request)
    }

    private func beginSearch(for request: SearchRequest) {
        overlayViewLogger.info("Starting index-only search for: '\(request.query)'")

        isSearchPending = false
        isSearchInProgress = true

        let searchCutoff = request.scope.cutoff(
            using: rewindHistoryOption,
            from: semanticReferenceDate
        )
        let cache = frameBuffer.textCache
        let activeDisplayID = activeDisplay?.id
        let includeLegacy = activeDisplay?.id == primaryDisplayID
        let leasedEntries = leasedTimelineEntries

        searchTask = Task {
            let matchedIDs = await cache.searchFrameIDs(matching: request.query, limit: 10_000, since: searchCutoff)

            guard !Task.isCancelled else { return }

            let matchedIDSet = Set(matchedIDs)
            let results = leasedEntries.filter { entry in
                guard matchedIDSet.contains(entry.frame.id) else { return false }
                if let searchCutoff, timelineSpanBounds(for: entry).end < searchCutoff {
                    return false
                }
                if let activeDisplayID {
                    if let entryDisplayID = entry.span.displayID {
                        return entryDisplayID == activeDisplayID
                    }
                    return includeLegacy
                }
                return true
            }

            guard !Task.isCancelled else { return }

            let finalResults = results
            await MainActor.run {
                if !Task.isCancelled {
                    let previousSpanID = selectedSpanID
                    let previousTimestamp = selectedTimestamp
                    searchResults = finalResults
                    isSearchInProgress = false
                    resolvedSearchRequest = request
                    reconcileSelection(
                        in: finalResults,
                        preferredSpanID: previousSpanID,
                        target: previousTimestamp,
                        preferLatestWhenMissing: false
                    )
                }
            }
        }
    }

    func setSelectedTimestamp(_ timestamp: Date) {
        guard let selection = resolveTimelineSelection(entries: displayedEntries, target: timestamp) else {
            selectedSpanID = nil
            selectedTimestamp = timelineReferenceDate
            return
        }
        selectedSpanID = selection.spanID
        selectedTimestamp = selection.timestamp
    }

    private func select(spanID: UUID, timestamp: Date) {
        guard let entry = displayedEntries.first(where: { $0.span.id == spanID }) else {
            setSelectedTimestamp(timestamp)
            return
        }
        let bounds = timelineSpanBounds(for: entry)
        selectedSpanID = spanID
        selectedTimestamp = min(max(timestamp, bounds.start), bounds.end)
    }

    private func selectLatest(in entries: [TimelineEntry]) {
        guard let selection = latestTimelineSelection(in: entries) else {
            selectedSpanID = nil
            selectedTimestamp = timelineReferenceDate
            return
        }
        selectedSpanID = selection.spanID
        selectedTimestamp = selection.timestamp
    }

    private func reconcileSelection(
        in entries: [TimelineEntry],
        preferredSpanID: UUID? = nil,
        target: Date? = nil,
        preferLatestWhenMissing: Bool
    ) {
        guard let selection = preservingTimelineSelection(
            in: entries,
            preferredSpanID: preferredSpanID ?? selectedSpanID,
            target: target ?? selectedTimestamp,
            preferLatestWhenMissing: preferLatestWhenMissing
        ) else {
            selectedSpanID = nil
            selectedTimestamp = timelineReferenceDate
            return
        }
        selectedSpanID = selection.spanID
        selectedTimestamp = selection.timestamp
    }

    private func ensureDisplayedSelection() -> Bool {
        // Search intentionally shows an empty result projection while its
        // first request is pending. Preserve the authoritative selection so a
        // matching logical span can be restored when results arrive.
        guard displayedFrameCount > 0 else { return false }
        if let selectedSpanID,
           displayedEntries.contains(where: { $0.span.id == selectedSpanID }) {
            return true
        }
        setSelectedTimestamp(selectedTimestamp)
        return true
    }
}
