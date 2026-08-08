//
//  OverlayWindowController.swift
//  JustNow
//

import AppKit
import SwiftUI
import Carbon.HIToolbox

/// Keeps the capture-resume callback behind the asynchronous RAM lease
/// release. A newer visible overlay invalidates an older hide operation, so a
/// delayed release cannot resume capture underneath that new overlay.
@MainActor
final class OverlayPayloadLeaseReleaseGate {
    private var visibilityGeneration = 0

    func becameVisible() -> Int {
        visibilityGeneration += 1
        return visibilityGeneration
    }

    func isCurrent(_ generation: Int) -> Bool {
        visibilityGeneration == generation
    }

    func release(
        _ lease: (any FrameRepositoryPayloadLease)?,
        generation: Int?,
        beforeResume: @escaping @MainActor (FrameRepositoryMaintenanceResult) async -> Void = { _ in },
        onReleasedForCurrentVisibility: @escaping () -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            let result = await lease?.release() ?? .noOp
            await beforeResume(result)
            if let generation {
                guard self?.visibilityGeneration == generation else { return }
            }
            onReleasedForCurrentVisibility()
        }
    }
}

@MainActor
class OverlayWindowController: NSObject {
    private var window: OverlayWindow?
    private let frameBuffer: FrameBuffer
    private let onVisibilityChanged: ((Bool) -> Void)?
    private let onOpenSettings: () -> Void
    private var dismissShortcutKeyCode: Int
    private var dismissShortcutModifiers: Int
    private var keyEventMonitor: Any?
    private var scrollEventMonitor: Any?
    private var timelineScrollAccumulator = TimelineScrollAccumulator()
    private var flagsChangedMonitor: Any?
    private(set) var viewModel: OverlayViewModel?
    private var payloadLease: (any FrameRepositoryPayloadLease)?
    private let payloadLeaseReleaseGate = OverlayPayloadLeaseReleaseGate()
    private var visibleGeneration: Int?
    private var pendingPresentationGeneration: Int?
    private var cancelledPresentationGenerations: Set<Int> = []
    private var payloadLeaseReleaseTask: Task<Void, Never>?
    private var defersCaptureResumeForMemoryPressure = false
    private var memoryPressureDismissedVisibleOverlay = false
    /// Once the overlay has actually paused capture, that obligation survives
    /// across newer presentation generations until the newest generation
    /// either becomes visible or aborts. This prevents an older hide callback
    /// from being invalidated while the newer abort incorrectly concludes
    /// there is nothing to resume.
    private var captureResumeRequired = false

    init(
        frameBuffer: FrameBuffer,
        dismissShortcutKeyCode: Int,
        dismissShortcutModifiers: Int,
        onVisibilityChanged: ((Bool) -> Void)? = nil,
        onOpenSettings: @escaping () -> Void
    ) {
        self.frameBuffer = frameBuffer
        self.dismissShortcutKeyCode = dismissShortcutKeyCode
        self.dismissShortcutModifiers = dismissShortcutModifiers
        self.onVisibilityChanged = onVisibilityChanged
        self.onOpenSettings = onOpenSettings
        super.init()
    }

    func updateDismissShortcut(keyCode: Int, modifiers: Int) {
        dismissShortcutKeyCode = keyCode
        dismissShortcutModifiers = modifiers
    }

    func showOverlay(
        recentTimelineWindow: TimeInterval,
        rewindHistoryOption: RewindHistoryOption,
        timelineScrollDirection: TimelineScrollDirection = .upToRewind,
        activeDisplay: DisplayInfo?,
        availableDisplays: [DisplayInfo]
    ) async {
        guard !defersCaptureResumeForMemoryPressure,
              window == nil,
              pendingPresentationGeneration == nil else { return }

        // Open on the screen that owns the active display; fall back to main.
        let resolvedScreen: NSScreen? = {
            if let activeDisplay,
               let displayID = activeDisplay.displayID,
               let screen = DisplayIdentity.screen(for: displayID) {
                return screen
            }
            return NSScreen.main
        }()
        guard let screen = resolvedScreen else { return }

        let primaryDisplayID = Self.primaryDisplayID(among: availableDisplays)
        let timelineReferenceDate = Date()

        // Retention must stop before the repository begins taking its
        // snapshot. Otherwise a forced policy update can delete durable
        // entries while snapshot acquisition is suspended, leaving the
        // overlay with metadata whose payload disappeared before its lease was
        // installed. This generation owns the pause until it either becomes
        // visible or releases an aborted snapshot.
        let presentationGeneration = payloadLeaseReleaseGate.becameVisible()
        let precedingReleaseTask = payloadLeaseReleaseTask
        pendingPresentationGeneration = presentationGeneration
        frameBuffer.isPruningPaused = true

        let leasedSnapshot = await frameBuffer.acquireCurrentTimelineSnapshotLease()
        let lease = leasedSnapshot.lease
        let wasExplicitlyCancelled = cancelledPresentationGenerations.remove(
            presentationGeneration
        ) != nil
        guard !Task.isCancelled,
              !wasExplicitlyCancelled,
              pendingPresentationGeneration == presentationGeneration,
              payloadLeaseReleaseGate.isCurrent(presentationGeneration),
              window == nil else {
            if pendingPresentationGeneration == presentationGeneration {
                pendingPresentationGeneration = nil
            }
            // If this was a reopen while the prior overlay was still
            // releasing, inherit that release barrier before satisfying the
            // transferred capture-resume obligation.
            await precedingReleaseTask?.value
            _ = await frameBuffer.releasePayloadLease(lease)
            finishReleasedOverlay(
                generation: presentationGeneration,
                shouldResumeCapture: false
            )
            return
        }
        pendingPresentationGeneration = nil

        // Filter only the exact repository snapshot whose volatile payloads
        // were atomically leased. Display switching and search use this same
        // snapshot, so no later unleased admission can surface in the overlay.
        let timelineEntries = frameBuffer.filteredTimelineEntries(
            from: leasedSnapshot.entries,
            recentWindow: recentTimelineWindow,
            maximumAge: rewindHistoryOption.duration,
            displayID: activeDisplay?.id,
            includeLegacyFrames: activeDisplay?.id == primaryDisplayID,
            now: timelineReferenceDate
        )

        // The overlay lease and pruning pause are separate protections: the
        // former protects volatile bytes under the hard RAM cap, while the
        // latter preserves retention semantics for the existing disk history.
        payloadLease = lease
        visibleGeneration = presentationGeneration
        let vm = OverlayViewModel(
            timelineEntries: timelineEntries,
            leasedTimelineEntries: leasedSnapshot.entries,
            frameBuffer: frameBuffer,
            recentTimelineWindow: recentTimelineWindow,
            rewindHistoryOption: rewindHistoryOption,
            availableDisplays: availableDisplays,
            activeDisplay: activeDisplay,
            primaryDisplayID: primaryDisplayID,
            timelineReferenceDate: timelineReferenceDate,
            onDismiss: { [weak self] in
                self?.hideOverlay()
            },
            onOpenSettings: onOpenSettings
        )
        self.viewModel = vm
        vm.isCommandHeld = NSEvent.modifierFlags.contains(.command)

        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.level = .statusBar + 1
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true

        let contentFrame = OverlayWindowLayout.contentFrame(forScreenFrame: screen.frame)
        let overlayView = OverlayView(viewModel: vm)
            .frame(width: contentFrame.width, height: contentFrame.height)
            .clipped()
        let hostingView = NSHostingView(rootView: overlayView)
        hostingView.frame = contentFrame
        hostingView.autoresizingMask = [.width, .height]
        // On macOS 13+, NSHostingView defaults to growing with its SwiftUI
        // content's intrinsic size. For a fullscreen overlay we explicitly
        // want the hosting view pinned to the window; otherwise SwiftUI's
        // maxWidth/maxHeight .infinity bubbles up and the hosting view
        // resizes beyond the window on each layout pass.
        if #available(macOS 13.0, *) {
            hostingView.sizingOptions = []
        }
        window.contentView = hostingView

        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        self.window = window

        // Monitor keyboard events
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let vm = self.viewModel else { return event }

            let action = resolveOverlayKeyboardAction(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags,
                dismissShortcutKeyCode: self.dismissShortcutKeyCode,
                dismissShortcutModifiers: self.dismissShortcutModifiers,
                state: OverlayKeyboardState(
                    isSearchAvailable: vm.isSearchAvailable,
                    isSearching: vm.isSearching,
                    hasSearchQuery: vm.hasSearchQuery,
                    isTextGrabActive: vm.isTextGrabActive
                )
            )

            switch action {
            case .passthrough:
                return event
            case .consume:
                return nil
            case .dismissOverlay:
                self.hideOverlay()
            case .cancelTextGrab:
                _ = vm.cancelTextGrabIfNeeded()
            case .clearSearch:
                vm.clearSearch()
            case .toggleSearch:
                vm.toggleSearch()
            case .submitSearch:
                vm.performSearch(immediately: true)
            case .moveLeft:
                vm.moveLeft()
            case .jumpLeft:
                vm.jumpLeft()
            case .goToStart:
                vm.goToStart()
            case .moveRight:
                vm.moveRight()
            case .jumpRight:
                vm.jumpRight()
            case .goToEnd:
                vm.goToEnd()
            case .cycleDisplayForward:
                vm.cycleDisplay(forward: true)
            case .cycleDisplayBackward:
                vm.cycleDisplay(forward: false)
            case .saveScreenshot:
                vm.saveCurrentFrameToScreenshotsLocation()
            case .openSettings:
                vm.openSettings()
            }

            return nil
        }

        // Track ⌘ state so the instructions pill and drag handler can switch
        // between the user's default drag action and the alternate action.
        flagsChangedMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // Only publish when the bit actually flips — Observation invalidates
            // subscribers on every assignment, equal-value writes included.
            let isHeld = event.modifierFlags.contains(.command)
            if self?.viewModel?.isCommandHeld != isHeld {
                self?.viewModel?.isCommandHeld = isHeld
            }
            return event
        }

        // Monitor scroll events
        timelineScrollAccumulator.reset()
        scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self, let vm = self.viewModel else { return event }
            guard timelineScrollDirection != .off else { return event }

            let delta = timelineScrollDirection.navigationDelta(
                horizontalDelta: event.scrollingDeltaX,
                verticalDelta: event.scrollingDeltaY
            )
            if let step = self.timelineScrollAccumulator.navigationStep(
                for: delta,
                hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
                isMomentum: !event.momentumPhase.isEmpty,
                beginsGesture: event.phase.contains(.began),
                endsGesture: event.phase.contains(.ended) || event.phase.contains(.cancelled)
            ) {
                vm.scrollBy(step)
            }
            return nil // Consume the event
        }

        NSApp.activate(ignoringOtherApps: true)
        captureResumeRequired = true
        onVisibilityChanged?(true)
    }

    func hideOverlay() {
        if let pendingPresentationGeneration,
           window == nil,
           viewModel == nil,
           payloadLease == nil {
            // Snapshot acquisition itself is not cancellable. Leave pruning
            // paused until that attempt returns and releases whatever it
            // acquired; a newer show attempt will take ownership through a
            // later generation in the meantime.
            cancelledPresentationGenerations.insert(pendingPresentationGeneration)
            self.pendingPresentationGeneration = nil
            return
        }
        guard window != nil || viewModel != nil || payloadLease != nil else { return }
        let dismissingViewModel = viewModel
        dismissingViewModel?.prepareForDismissal()

        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
        if let monitor = scrollEventMonitor {
            NSEvent.removeMonitor(monitor)
            scrollEventMonitor = nil
        }
        if let monitor = flagsChangedMonitor {
            NSEvent.removeMonitor(monitor)
            flagsChangedMonitor = nil
        }
        window?.orderOut(nil)
        window = nil
        viewModel = nil
        let lease = payloadLease
        payloadLease = nil
        let generation = visibleGeneration
        visibleGeneration = nil
        payloadLeaseReleaseTask = payloadLeaseReleaseGate.release(
            nil,
            generation: generation,
            beforeResume: { [weak self] _ in
                await dismissingViewModel?.waitForPendingScreenshotSaves()
                guard let self, let lease else { return }
                _ = await self.frameBuffer.releasePayloadLease(lease)
            }
        ) { [weak self] in
            self?.finishReleasedOverlay(
                generation: generation,
                shouldResumeCapture: true
            )
            if dismissingViewModel?.shouldShowQualityInfoOnDismiss == true {
                // Run-loop tick so the overlay is fully torn down before the
                // alert grabs key. Without this the alert briefly appears
                // behind the dismissing window on slower machines.
                DispatchQueue.main.async { [weak self] in
                    self?.presentSaveQualityInfoAlert()
                }
            }
        }
    }

    /// Tears down any pending or visible overlay and waits for its known RAM
    /// lease without resuming capture. AppDelegate completes the dismissal
    /// only after critical repository and decoded-cache reclamation finishes.
    @discardableResult
    func dismissForMemoryPressure() async -> Bool {
        defersCaptureResumeForMemoryPressure = true

        if let pendingPresentationGeneration,
           window == nil,
           viewModel == nil,
           payloadLease == nil {
            cancelledPresentationGenerations.insert(pendingPresentationGeneration)
            self.pendingPresentationGeneration = nil
        }

        if let payloadLeaseReleaseTask {
            await payloadLeaseReleaseTask.value
            self.payloadLeaseReleaseTask = nil
        }

        let wasVisible = window != nil || viewModel != nil || payloadLease != nil
        guard wasVisible else { return memoryPressureDismissedVisibleOverlay }

        let dismissingViewModel = viewModel
        dismissingViewModel?.prepareForDismissal()
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
        if let monitor = scrollEventMonitor {
            NSEvent.removeMonitor(monitor)
            scrollEventMonitor = nil
        }
        if let monitor = flagsChangedMonitor {
            NSEvent.removeMonitor(monitor)
            flagsChangedMonitor = nil
        }
        window?.orderOut(nil)
        window = nil
        viewModel = nil

        let lease = payloadLease
        payloadLease = nil
        let generation = visibleGeneration
        visibleGeneration = nil
        await dismissingViewModel?.waitForPendingScreenshotSaves()
        if let lease {
            _ = await frameBuffer.releasePayloadLease(lease)
        }
        if generation.map(payloadLeaseReleaseGate.isCurrent) ?? true {
            memoryPressureDismissedVisibleOverlay =
                memoryPressureDismissedVisibleOverlay || captureResumeRequired
        }
        return memoryPressureDismissedVisibleOverlay
    }

    func completeMemoryPressureDismissal() {
        let shouldResumeCapture = memoryPressureDismissedVisibleOverlay
        memoryPressureDismissedVisibleOverlay = false
        defersCaptureResumeForMemoryPressure = false
        frameBuffer.isPruningPaused = false
        if shouldResumeCapture {
            captureResumeRequired = false
            onVisibilityChanged?(false)
        }
    }

    private func finishReleasedOverlay(
        generation: Int?,
        shouldResumeCapture: Bool
    ) {
        if let generation,
           !payloadLeaseReleaseGate.isCurrent(generation) {
            return
        }
        if defersCaptureResumeForMemoryPressure {
            memoryPressureDismissedVisibleOverlay =
                memoryPressureDismissedVisibleOverlay
                    || shouldResumeCapture
                    || captureResumeRequired
            return
        }
        frameBuffer.isPruningPaused = false
        if shouldResumeCapture || captureResumeRequired {
            captureResumeRequired = false
            onVisibilityChanged?(false)
        }
    }

    private func presentSaveQualityInfoAlert() {
        let alert = NSAlert()
        alert.messageText = "About JustNow saves"
        alert.informativeText = """
        JustNow saves screenshots from its rewind history rather than re-capturing the screen, so saves aren't pixel-identical to ⇧⌘3:

        • Format: JPEG (the same compression JustNow uses for the rewind history).
        • Resolution: full pixel density when plugged in. Halved when capturing on battery or in Low Power Mode for performance.

        You can adjust these in Settings.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Got it")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    var isVisible: Bool {
        window?.isVisible == true
    }

    /// Picks the built-in display first, else the first in the list. Legacy
    /// (pre-multi-display) frames surface under whichever display wins this.
    private static func primaryDisplayID(among displays: [DisplayInfo]) -> UUID? {
        if let builtIn = displays.first(where: { info in
            guard let did = info.displayID else { return false }
            return CGDisplayIsBuiltin(did) != 0
        }) {
            return builtIn.id
        }
        return displays.first(where: { $0.isConnected })?.id ?? displays.first?.id
    }
}

// Custom window that can become key
class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

enum OverlayWindowLayout {
    static func contentFrame(forScreenFrame screenFrame: CGRect) -> CGRect {
        CGRect(origin: .zero, size: screenFrame.size)
    }
}
