//
//  OverlayViewModel.swift
//  JustNow
//

import CoreGraphics
import Foundation
import Observation
import SwiftUI
import os.log

private let overlayViewLogger = Logger(subsystem: "sg.tk.JustNow", category: "OverlayView")

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
    private struct SearchRequest: Equatable {
        let query: String
        let scope: SearchTimeScope
    }

    private static let searchDebounceDelay: Duration = .milliseconds(220)
    private static let fullImagePrefetchRadius = 3

    var selectedIndex: Int = 0
    var presentedFrame: StoredFrame?
    private(set) var timelineFrames: [StoredFrame]
    let frameBuffer: FrameBuffer
    let recentTimelineWindow: TimeInterval
    let rewindHistoryOption: RewindHistoryOption
    let timelineReferenceDate: Date
    let onDismiss: () -> Void
    let availableDisplays: [DisplayInfo]
    private(set) var activeDisplay: DisplayInfo?
    private let primaryDisplayID: UUID?

    var isSearching = false
    var searchQuery = ""
    var searchTimeScope: SearchTimeScope = .all
    var searchResults: [StoredFrame] = []
    var isSearchPending = false
    var isSearchInProgress = false
    var searchIndexStatus: SearchIndexStatus = .empty
    private var searchDebounceTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var imagePrefetchTask: Task<Void, Never>?
    private var resolvedSearchRequest: SearchRequest?
    var isTextGrabActive = false
    private var cancelTextGrabHandler: (() -> Void)?

    var isSearchAvailable: Bool {
        FeatureFlags.isSearchEnabled
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

    var selectedFramePrefetchKey: String {
        let selectedFrameID = displayedFrames[safe: selectedIndex]?.id.uuidString ?? "none"
        return "\(selectedFrameID)|\(displayedFrameCount)"
    }

    var displayedFrames: [StoredFrame] {
        isSearchAvailable && isSearching && hasSearchQuery ? searchResults : timelineFrames
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

    var hasRetainedFrames: Bool {
        frameBuffer.frameCount > 0
    }

    var hasAnyFrames: Bool {
        !timelineFrames.isEmpty || hasRetainedFrames
    }

    init(
        timelineFrames: [StoredFrame],
        frameBuffer: FrameBuffer,
        recentTimelineWindow: TimeInterval,
        rewindHistoryOption: RewindHistoryOption,
        availableDisplays: [DisplayInfo],
        activeDisplay: DisplayInfo?,
        primaryDisplayID: UUID?,
        onDismiss: @escaping () -> Void
    ) {
        self.timelineFrames = timelineFrames
        self.frameBuffer = frameBuffer
        self.recentTimelineWindow = recentTimelineWindow
        self.rewindHistoryOption = rewindHistoryOption
        self.timelineReferenceDate = Date()
        self.availableDisplays = availableDisplays
        self.activeDisplay = activeDisplay
        self.primaryDisplayID = primaryDisplayID
        self.onDismiss = onDismiss
        self.selectedIndex = max(0, timelineFrames.count - 1)
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
        selectedIndex = max(0, timelineFrames.count - 1)
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
            return
        }

        searchResults = []
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
        let newFrames = frameBuffer.getFilteredFrames(
            recentWindow: recentTimelineWindow,
            maximumAge: rewindHistoryOption.duration,
            displayID: display.id,
            includeLegacyFrames: display.id == primaryDisplayID
        )
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            clearSearch()
            activeDisplay = display
            timelineFrames = newFrames
            selectedIndex = max(0, newFrames.count - 1)
            presentedFrame = nil
        }
    }

    func prefetchImagesNearSelection() {
        imagePrefetchTask?.cancel()
        imagePrefetchTask = nil

        guard ensureDisplayedSelection() else { return }

        let lowerBound = max(0, selectedIndex - Self.fullImagePrefetchRadius)
        let upperBound = min(displayedFrameCount - 1, selectedIndex + Self.fullImagePrefetchRadius)
        let framesToPrefetch = (lowerBound...upperBound).compactMap { index -> StoredFrame? in
            guard index != selectedIndex else { return nil }
            return displayedFrames[safe: index]
        }
        guard !framesToPrefetch.isEmpty else { return }

        let buffer = frameBuffer
        imagePrefetchTask = Task(priority: .utility) {
            await buffer.prefetchFullImages(for: framesToPrefetch)
        }
    }

    func scrollBy(_ delta: CGFloat) {
        guard ensureDisplayedSelection() else { return }
        let step = delta > 0 ? -1 : 1
        let newIndex = selectedIndex + step
        selectedIndex = max(0, min(displayedFrameCount - 1, newIndex))
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

        let searchCutoff = request.scope.cutoff(using: rewindHistoryOption)
        let buffer = frameBuffer
        let cache = frameBuffer.textCache
        let activeDisplayID = activeDisplay?.id
        let includeLegacy = activeDisplay?.id == primaryDisplayID

        searchTask = Task {
            let matchedIDs = await cache.searchFrameIDs(matching: request.query, limit: 10_000, since: searchCutoff)

            guard !Task.isCancelled else { return }

            let allFrames = buffer.getFrames()
            let frameByID = Dictionary(uniqueKeysWithValues: allFrames.map { ($0.id, $0) })
            var results: [StoredFrame] = []
            results.reserveCapacity(matchedIDs.count)
            for matchedID in matchedIDs {
                guard let frame = frameByID[matchedID] else { continue }
                if let activeDisplayID {
                    if let frameDisplayID = frame.displayID {
                        guard frameDisplayID == activeDisplayID else { continue }
                    } else if !includeLegacy {
                        continue
                    }
                }
                results.append(frame)
            }
            results.reverse()

            guard !Task.isCancelled else { return }

            let finalResults = results
            await MainActor.run {
                if !Task.isCancelled {
                    searchResults = finalResults
                    isSearchInProgress = false
                    resolvedSearchRequest = request
                    selectedIndex = max(0, finalResults.count - 1)
                }
            }
        }
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
