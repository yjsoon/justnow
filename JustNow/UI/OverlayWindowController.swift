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
        rewindHistoryOption: RewindHistoryOption
    ) {
        guard window == nil, let screen = NSScreen.main else { return }

        // Pause pruning while overlay is visible
        frameBuffer.isPruningPaused = true

        // Get frames with near-duplicates filtered out for smoother browsing
        let timelineFrames = frameBuffer.getFilteredFrames(
            recentWindow: recentTimelineWindow,
            maximumAge: rewindHistoryOption.duration
        )
        let vm = OverlayViewModel(
            timelineFrames: timelineFrames,
            frameBuffer: frameBuffer,
            recentTimelineWindow: recentTimelineWindow,
            rewindHistoryOption: rewindHistoryOption,
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
        window.backgroundColor = NSColor.black.withAlphaComponent(0.92)
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true

        let overlayView = OverlayView(viewModel: vm)
        let hostingView = NSHostingView(rootView: overlayView)
        hostingView.frame = screen.frame
        hostingView.autoresizingMask = [.width, .height]
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
}

// Custom window that can become key
class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
