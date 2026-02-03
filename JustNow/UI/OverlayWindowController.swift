//
//  OverlayWindowController.swift
//  JustNow
//

import AppKit
import SwiftUI

class OverlayWindowController: NSObject {
    private var window: OverlayWindow?
    private let frameBuffer: FrameBuffer
    private let onVisibilityChanged: ((Bool) -> Void)?
    private var keyEventMonitor: Any?
    private var scrollEventMonitor: Any?
    private var viewModel: OverlayViewModel?

    init(frameBuffer: FrameBuffer, onVisibilityChanged: ((Bool) -> Void)? = nil) {
        self.frameBuffer = frameBuffer
        self.onVisibilityChanged = onVisibilityChanged
        super.init()
    }

    func showOverlay() {
        guard window == nil, let screen = NSScreen.main else { return }

        // Pause pruning while overlay is visible
        frameBuffer.isPruningPaused = true

        // Get frames with near-duplicates filtered out for smoother browsing
        let frames = frameBuffer.getFilteredFrames()
        let vm = OverlayViewModel(frames: frames, frameBuffer: frameBuffer, onDismiss: { [weak self] in
            self?.hideOverlay()
        })
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

            switch event.keyCode {
            case 53: // ESC
                if vm.isSearching {
                    vm.clearSearch()
                    vm.isSearching = false
                } else {
                    self.hideOverlay()
                }
                return nil
            case 44: // "/" key - toggle search
                if !vm.isSearching {
                    vm.toggleSearch()
                    return nil
                }
                return event // Pass through if already searching (for typing)
            case 36: // Return key - trigger search
                if vm.isSearching && !vm.searchQuery.isEmpty {
                    print("[JustNow] Return key pressed, triggering search")
                    vm.performSearch()
                    return nil
                }
                return event
            case 123: // Left arrow
                if vm.isSearching { return event } // Let text field handle it
                if event.modifierFlags.contains(.command) {
                    vm.goToStart()
                } else if event.modifierFlags.contains(.option) {
                    vm.jumpLeft()
                } else {
                    vm.moveLeft()
                }
                return nil
            case 124: // Right arrow
                if vm.isSearching { return event } // Let text field handle it
                if event.modifierFlags.contains(.command) {
                    vm.goToEnd()
                } else if event.modifierFlags.contains(.option) {
                    vm.jumpRight()
                } else {
                    vm.moveRight()
                }
                return nil
            default:
                return event
            }
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
