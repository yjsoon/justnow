//
//  OverlayWindowController.swift
//  JustNow
//

import AppKit
import SwiftUI

class OverlayWindowController: NSObject {
    private var window: OverlayWindow?
    private let frameBuffer: FrameBuffer
    private var eventMonitor: Any?

    init(frameBuffer: FrameBuffer) {
        self.frameBuffer = frameBuffer
        super.init()
    }

    func showOverlay() {
        guard window == nil, let screen = NSScreen.main else { return }

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

        let overlayView = OverlayView(
            frames: frameBuffer.getFrames(),
            onDismiss: { [weak self] in self?.hideOverlay() }
        )

        let hostingView = NSHostingView(rootView: overlayView)
        hostingView.frame = window.contentView?.bounds ?? screen.frame
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView

        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        // Monitor for ESC key
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // ESC
                self?.hideOverlay()
                return nil
            }
            return event
        }

        self.window = window

        // Activate the app to ensure keyboard events work
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideOverlay() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        window?.orderOut(nil)
        window = nil
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
