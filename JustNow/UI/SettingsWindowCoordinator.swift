//
//  SettingsWindowCoordinator.swift
//  JustNow
//

import AppKit

@MainActor
final class SettingsWindowCoordinator: NSObject, NSWindowDelegate {
    private let makeContentView: @MainActor () -> NSView
    private let activateApp: @MainActor () -> Void
    private(set) var window: NSWindow?

    init(
        makeContentView: @escaping @MainActor () -> NSView,
        activateApp: @escaping @MainActor () -> Void = {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    ) {
        self.makeContentView = makeContentView
        self.activateApp = activateApp
        super.init()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            activateApp()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 680),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = "JustNow Settings"
        window.contentView = makeContentView()
        window.center()
        window.makeKeyAndOrderFront(nil)
        activateApp()

        self.window = window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else {
            return true
        }

        sender.orderOut(nil)
        return false
    }
}
