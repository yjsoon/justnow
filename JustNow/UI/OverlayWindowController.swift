//
//  OverlayWindowController.swift
//  JustNow
//

import AppKit
import SwiftUI

class OverlayWindowController: NSObject {
    private var window: OverlayWindow?
    private let frameBuffer: FrameBuffer
    private var keyEventMonitor: Any?
    private var scrollEventMonitor: Any?
    private var viewModel: OverlayViewModel?

    init(frameBuffer: FrameBuffer) {
        self.frameBuffer = frameBuffer
        super.init()
    }

    func showOverlay() {
        guard window == nil, let screen = NSScreen.main else { return }

        let frames = frameBuffer.getFrames()
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

        let overlayView = OverlayView(frames: frames, frameBuffer: frameBuffer, onDismiss: { [weak self] in
            self?.hideOverlay()
        })
        // Replace the view's viewModel with our shared one
        var view = overlayView
        view.viewModel = vm

        let hostingView = NSHostingView(rootView: view)
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

            switch event.keyCode {
            case 53: // ESC
                self.hideOverlay()
                return nil
            case 123: // Left arrow
                if event.modifierFlags.contains(.command) {
                    vm.goToStart()
                } else if event.modifierFlags.contains(.option) {
                    vm.jumpLeft()
                } else {
                    vm.moveLeft()
                }
                return nil
            case 124: // Right arrow
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
    }

    func hideOverlay() {
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
