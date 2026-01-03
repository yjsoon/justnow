//
//  OverlayWindowController.swift
//  JustNow
//

import AppKit
import SwiftUI

class OverlayWindowController {
    private var panel: NSPanel?
    private let frameBuffer: FrameBuffer

    init(frameBuffer: FrameBuffer) {
        self.frameBuffer = frameBuffer
    }

    func showOverlay() {
        guard panel == nil, let screen = NSScreen.main else { return }

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.9)
        panel.hasShadow = false

        let overlayView = OverlayView(
            frames: frameBuffer.getFrames(),
            onDismiss: { [weak self] in self?.hideOverlay() }
        )

        panel.contentView = NSHostingView(rootView: overlayView.ignoresSafeArea())
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.panel = panel
    }

    func hideOverlay() {
        panel?.orderOut(nil)
        panel = nil
    }

    var isVisible: Bool {
        panel != nil
    }
}
