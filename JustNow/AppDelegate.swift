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
    private var settingsWindow: NSWindow?

    @AppStorage("captureInterval") private var captureInterval: Double = 1.0
    @AppStorage("maxFrames") private var maxFrames: Int = 600
    @AppStorage("reduceCaptureOnBattery") private var reduceCaptureOnBattery: Bool = true

    private var powerCheckTimer: Timer?
    private var frameCountTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupHotKey()
        setupCapture()
        setupTimers()
        setupSleepWakeObservers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appNapPreventer.stopActivity()
        powerCheckTimer?.invalidate()
        frameCountTimer?.invalidate()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "JustNow")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

        let showItem = NSMenuItem(title: "Show Timeline", action: #selector(showOverlay), keyEquivalent: "")
        showItem.target = self
        showItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(showItem)

        menu.addItem(NSMenuItem.separator())

        let frameCountItem = NSMenuItem(title: "Frames: 0", action: nil, keyEquivalent: "")
        frameCountItem.tag = 100
        frameCountItem.isEnabled = false
        menu.addItem(frameCountItem)

        let captureStatusItem = NSMenuItem(title: "Capture: Starting...", action: nil, keyEquivalent: "")
        captureStatusItem.tag = 101
        captureStatusItem.isEnabled = false
        menu.addItem(captureStatusItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit JustNow", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func setupHotKey() {
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
                updateCaptureStatus("Active")
                updateCaptureInterval()
            } catch CaptureError.permissionDenied {
                updateCaptureStatus("No Permission")
                showPermissionAlert()
            } catch {
                updateCaptureStatus("Error")
                showErrorAlert(error)
            }
        }
    }

    private func setupTimers() {
        // Update frame count every 2 seconds
        frameCountTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateFrameCountMenuItem()
        }

        // Check power state every minute
        powerCheckTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.updateCaptureInterval()
        }
    }

    private func setupSleepWakeObservers() {
        let workspace = NSWorkspace.shared.notificationCenter

        workspace.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        workspace.addObserver(
            self,
            selector: #selector(handleSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
    }

    @objc private func handleSleep() {
        updateCaptureStatus("Sleeping...")
    }

    @objc private func handleWake() {
        // Restart capture after wake - stream may have been invalidated
        Task { @MainActor in
            await captureManager.stopCapture()

            // Small delay to let system stabilise after wake
            try? await Task.sleep(for: .seconds(1))

            do {
                try await captureManager.startCapture()
                updateCaptureStatus("Active")
            } catch {
                updateCaptureStatus("Error")
            }
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
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "JustNow Settings"
        window.contentView = NSHostingView(rootView: SettingsView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func updateCaptureInterval() {
        guard reduceCaptureOnBattery else { return }

        Task {
            let interval: Double
            if PowerManager.isOnBattery() {
                interval = captureInterval * 2.0
            } else {
                interval = captureInterval
            }

            let cmTime = CMTime(seconds: interval, preferredTimescale: 1)
            try? await captureManager.updateCaptureInterval(cmTime)
        }
    }

    private func updateFrameCountMenuItem() {
        guard let menu = statusItem.menu else { return }

        if let item = menu.item(withTag: 100) {
            let count = frameBuffer.frameCount
            item.title = "Frames: \(count)"
        }
    }

    private func updateCaptureStatus(_ status: String) {
        guard let menu = statusItem.menu,
              let item = menu.item(withTag: 101) else { return }
        item.title = "Capture: \(status)"
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "JustNow needs screen recording permission to capture your screen history.\n\nPlease grant permission in System Settings → Privacy & Security → Screen Recording, then restart the app."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")

        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
        NSApp.terminate(nil)
    }

    private func showErrorAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Capture Error"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
