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
    let onOpenSettings: () -> Void
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

    var saveToast: OverlayToast?
    private var saveToastTask: Task<Void, Never>?

    /// Tracks whether ⌘ is currently held inside the overlay window. The
    /// modifier-flag monitor in OverlayWindowController writes here so the
    /// instructions pill and selection drag handler can switch to
    /// "screenshot region" mode without each component owning a monitor.
    var isCommandHeld: Bool = false

    /// Set true by the "Save Region…" menu item so the very next drag
    /// performs a region screenshot without requiring ⌘. The drag handler
    /// clears it after consuming, so this is one-shot.
    var isRegionScreenshotArmed: Bool = false

    /// Either path that should make the next drag perform a region
    /// screenshot — live ⌘ hold or armed via the menu.
    var isInRegionScreenshotMode: Bool {
        isCommandHeld || isRegionScreenshotArmed
    }

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
        onDismiss: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
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
        self.onOpenSettings = onOpenSettings
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

    var canSaveCurrentFrame: Bool {
        displayedFrames[safe: selectedIndex] != nil
    }

    func openSettings() {
        onDismiss()
        onOpenSettings()
    }

    func saveCurrentFrameToScreenshotsLocation() {
        guard let frame = displayedFrames[safe: selectedIndex] else { return }
        let buffer = frameBuffer
        performScreenshotSave(operationName: "current frame") { destinations in
            var savedURL: URL? = nil
            if destinations.toFolder {
                savedURL = try await buffer.saveFrameToScreenshotsLocation(frame)
            }
            if destinations.toClipboard {
                let image = try await buffer.getFullImage(for: frame)
                Self.copyImageToClipboard(image)
            }
            return savedURL
        }
    }

    /// Save a region cropped from the displayed frame. Called by the
    /// drag-to-region path when ⌘ is held during the drag.
    func saveCroppedScreenshot(image: CGImage) {
        let buffer = frameBuffer
        performScreenshotSave(operationName: "cropped region") { destinations in
            var savedURL: URL? = nil
            if destinations.toFolder {
                savedURL = try await buffer.saveCroppedImageToScreenshotsLocation(image)
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
        let destinations = currentSaveDestinations()
        Task { @MainActor in
            do {
                let savedURL = try await operation(destinations)
                playSavedSoundIfNeeded()
                showSaveToast(makeSuccessToast(savedURL: savedURL, destinations: destinations))
                markQualityInfoPendingIfNeeded()
            } catch {
                overlayViewLogger.error(
                    "Failed screenshot save (\(operationName, privacy: .public)): \(error.localizedDescription, privacy: .public)"
                )
                showSaveToast(makeErrorToast(error))
            }
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
            title: "Couldn't save screenshot",
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

    /// Triggered by the "Save Region…" menu item: behave as if ⌘ is held
    /// for the next drag, and briefly teach the ⌘-drag shortcut the first
    /// couple of times the menu path is used.
    func armRegionScreenshot() {
        isRegionScreenshotArmed = true
        let defaults = UserDefaults.standard
        let hintCount = defaults.integer(forKey: AppStorageKey.regionScreenshotShortcutHintCount)
        let title: String
        if hintCount < 2 {
            title = "Drag to capture. You can also hold \u{2318} and drag."
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

    func dismissSaveToast() {
        saveToastTask?.cancel()
        saveToastTask = nil
        saveToast = nil
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

        let searchCutoff = request.scope.cutoff(using: rewindHistoryOption)
        let buffer = frameBuffer
        let cache = frameBuffer.textCache
        let activeDisplayID = activeDisplay?.id
        let includeLegacy = activeDisplay?.id == primaryDisplayID

        searchTask = Task {
            let matchedIDs = await cache.searchFrameIDs(matching: request.query, limit: 10_000, since: searchCutoff)

            guard !Task.isCancelled else { return }

            let matchedFrames = buffer.frames(withIDs: matchedIDs)
            var results: [StoredFrame] = []
            results.reserveCapacity(matchedFrames.count)
            for frame in matchedFrames {
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
