//
//  AppDelegate.swift
//  JustNow
//

import AppKit
import SwiftUI
import HotKey
import CoreMedia

class AppDelegate: NSObject, NSApplicationDelegate, ScreenCaptureDelegate {
    private var statusItem: NSStatusItem!
    private var captureManager: ScreenCaptureManager!
    private var frameBuffer: FrameBuffer!
    private var overlayController: OverlayWindowController?
    private var hotKey: HotKey?
    private var appNapPreventer = AppNapPreventer()

    @AppStorage("captureInterval") private var captureInterval: Double = 1.0
    @AppStorage("maxFrames") private var maxFrames: Int = 600
    @AppStorage("reduceCaptureOnBattery") private var reduceCaptureOnBattery: Bool = true

    private var powerObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupHotKey()
        setupCapture()
        setupPowerObserver()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appNapPreventer.stopActivity()
        if let observer = powerObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "JustNow")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Timeline (⌘⌥R)", action: #selector(showOverlay), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let frameCountItem = NSMenuItem(title: "Frames: 0", action: nil, keyEquivalent: "")
        frameCountItem.tag = 100
        menu.addItem(frameCountItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu

        // Update frame count periodically
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateFrameCountMenuItem()
        }
    }

    private func setupHotKey() {
        // Cmd+Option+R to show overlay
        hotKey = HotKey(key: .r, modifiers: [.command, .option])
        hotKey?.keyDownHandler = { [weak self] in
            self?.toggleOverlay()
        }
    }

    private func setupCapture() {
        captureManager = ScreenCaptureManager()
        frameBuffer = FrameBuffer()
        frameBuffer.maxFrames = maxFrames

        Task { @MainActor in
            captureManager.delegate = self

            do {
                try await captureManager.startCapture()
                appNapPreventer.startActivity()
                updateCaptureInterval()
            } catch CaptureError.permissionDenied {
                showPermissionAlert()
            } catch {
                showErrorAlert(error)
            }
        }
    }

    private func setupPowerObserver() {
        powerObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("com.apple.system.config.network_change"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateCaptureInterval()
        }

        // Also check periodically
        Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.updateCaptureInterval()
        }
    }

    // MARK: - Capture Delegate

    func captureManager(_ manager: ScreenCaptureManager, didCaptureFrame pixelBuffer: CVPixelBuffer, at timestamp: Date) {
        frameBuffer.addFrame(pixelBuffer, timestamp: timestamp)
    }

    // MARK: - Actions

    @objc private func toggleOverlay() {
        if let controller = overlayController, controller.isVisible {
            controller.hideOverlay()
        } else {
            showOverlay()
        }
    }

    @objc private func showOverlay() {
        if overlayController == nil {
            overlayController = OverlayWindowController(frameBuffer: frameBuffer)
        }
        overlayController?.showOverlay()
    }

    @objc private func showSettings() {
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 350),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "JustNow Settings"
        settingsWindow.contentView = NSHostingView(rootView: SettingsView())
        settingsWindow.center()
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Helpers

    private func updateCaptureInterval() {
        guard reduceCaptureOnBattery else { return }

        Task {
            let interval: Double
            if PowerManager.isOnBattery() {
                interval = captureInterval * 2.0 // Slower on battery
            } else {
                interval = captureInterval
            }

            let cmTime = CMTime(seconds: interval, preferredTimescale: 1)
            try? await captureManager.updateCaptureInterval(cmTime)
        }
    }

    private func updateFrameCountMenuItem() {
        if let menu = statusItem.menu,
           let item = menu.item(withTag: 100) {
            item.title = "Frames: \(frameBuffer.frameCount)"
        }
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "JustNow needs screen recording permission to capture your screen history. Please grant permission in System Settings → Privacy & Security → Screen Recording."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        } else {
            NSApp.terminate(nil)
        }
    }

    private func showErrorAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Capture Error"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
    }
}
