//
//  OverlayWindowController.swift
//  JustNow
//

import AppKit
import SwiftUI
import Carbon.HIToolbox

@MainActor
class OverlayWindowController: NSObject {
    private var window: OverlayWindow?
    private let frameBuffer: FrameBuffer
    private let onVisibilityChanged: ((Bool) -> Void)?
    private var dismissShortcutKeyCode: Int
    private var dismissShortcutModifiers: Int
    private var keyEventMonitor: Any?
    private var scrollEventMonitor: Any?
    private var viewModel: OverlayViewModel?

    init(
        frameBuffer: FrameBuffer,
        dismissShortcutKeyCode: Int,
        dismissShortcutModifiers: Int,
        onVisibilityChanged: ((Bool) -> Void)? = nil
    ) {
        self.frameBuffer = frameBuffer
        self.dismissShortcutKeyCode = dismissShortcutKeyCode
        self.dismissShortcutModifiers = dismissShortcutModifiers
        self.onVisibilityChanged = onVisibilityChanged
        super.init()
    }

    func updateDismissShortcut(keyCode: Int, modifiers: Int) {
        dismissShortcutKeyCode = keyCode
        dismissShortcutModifiers = modifiers
    }

    func showOverlay(
        recentTimelineWindow: TimeInterval,
        rewindHistoryOption: RewindHistoryOption,
        activeDisplay: DisplayInfo?,
        availableDisplays: [DisplayInfo]
    ) {
        guard window == nil else { return }

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

        // Pause pruning while overlay is visible
        frameBuffer.isPruningPaused = true

        let primaryDisplayID = Self.primaryDisplayID(among: availableDisplays)

        // Get frames with near-duplicates filtered out for smoother browsing.
        // Legacy (nil displayID) frames predate multi-display support so their
        // source display is ambiguous — they stay hidden from display-scoped
        // timelines rather than polluting whichever slot happens to be primary.
        let timelineFrames = frameBuffer.getFilteredFrames(
            recentWindow: recentTimelineWindow,
            maximumAge: rewindHistoryOption.duration,
            displayID: activeDisplay?.id,
            includeLegacyFrames: activeDisplay?.id == primaryDisplayID
        )
        let vm = OverlayViewModel(
            timelineFrames: timelineFrames,
            frameBuffer: frameBuffer,
            recentTimelineWindow: recentTimelineWindow,
            rewindHistoryOption: rewindHistoryOption,
            availableDisplays: availableDisplays,
            activeDisplay: activeDisplay,
            primaryDisplayID: primaryDisplayID,
            onDismiss: { [weak self] in
                self?.hideOverlay()
            }
        )
        self.viewModel = vm

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

        let overlayView = OverlayView(viewModel: vm)
            .frame(width: screen.frame.width, height: screen.frame.height)
            .clipped()
        let hostingView = NSHostingView(rootView: overlayView)
        hostingView.frame = screen.frame
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

            print("[JustNow] Key pressed: keyCode=\(event.keyCode), chars='\(event.characters ?? "")'")

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
            }

            return nil
        }

        // Monitor scroll events
        scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self, let vm = self.viewModel else { return event }

            // Use horizontal scroll or vertical scroll
            let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : -event.scrollingDeltaY

            if abs(delta) > 1 {
                vm.scrollBy(delta)
            }
            return nil // Consume the event
        }

        NSApp.activate(ignoringOtherApps: true)
        onVisibilityChanged?(true)
    }

    func hideOverlay() {
        // Resume pruning
        frameBuffer.isPruningPaused = false
        viewModel?.clearSearch()

        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
        if let monitor = scrollEventMonitor {
            NSEvent.removeMonitor(monitor)
            scrollEventMonitor = nil
        }
        window?.orderOut(nil)
        window = nil
        viewModel = nil
        onVisibilityChanged?(false)
    }

    var isVisible: Bool {
        window != nil && window!.isVisible
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
