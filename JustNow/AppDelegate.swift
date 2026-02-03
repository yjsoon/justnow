//
//  AppDelegate.swift
//  JustNow
//

import AppKit
import CoreGraphics
import SwiftUI
import HotKey
import Carbon.HIToolbox

class AppDelegate: NSObject, NSApplicationDelegate, ScreenCaptureDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var captureManager: ScreenCaptureManager!
    private var frameBuffer: FrameBuffer?
    private var overlayController: OverlayWindowController?
    private var hotKey: HotKey?
    private var appNapPreventer = AppNapPreventer()
    private var settingsWindow: NSWindow?

    @AppStorage("captureInterval") private var captureInterval: Double = 0.5
    @AppStorage("reduceCaptureOnBattery") private var reduceCaptureOnBattery: Bool = true
    @AppStorage("shortcutKeyCode") private var shortcutKeyCode: Int = 15  // R key
    @AppStorage("shortcutModifiers") private var shortcutModifiers: Int = 1_572_864  // ⌘⌥

    private var capturePolicyTimer: Timer?
    private var userDefaultsObserver: NSObjectProtocol?
    private var thermalObserver: NSObjectProtocol?
    private var lastAppliedPolicy: CapturePolicy?
    private var wasCapturingBeforeOverlay = false
    private var isPausedForOverlay = false

    private let idleThreshold: TimeInterval = 60
    private let idleMultiplier: Double = 4
    private let batteryMultiplier: Double = 3
    private let thermalSeriousMultiplier: Double = 2
    private let thermalCriticalMultiplier: Double = 4
    private let maxCaptureInterval: Double = 30

    private struct CapturePolicy: Equatable {
        let interval: TimeInterval
        let scale: Int
        let saveOptions: FrameSaveOptions
        let duplicatePolicy: DuplicateFramePolicy
        let shouldPreventAppNap: Bool
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupHotKey()
        setupCapture()
        setupTimers()
        setupObservers()
        setupSleepWakeObservers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appNapPreventer.stopActivity()
        capturePolicyTimer?.invalidate()
        if let observer = userDefaultsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = thermalObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        Task { @MainActor in
            await frameBuffer?.flushCaches()
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

        menu.delegate = self
        statusItem.menu = menu
    }

    private func setupHotKey() {
        registerHotKey()
    }

    func registerHotKey() {
        // Clear existing hotkey
        hotKey = nil

        // Don't register if no shortcut set
        guard shortcutKeyCode != -1 else { return }

        // Convert stored modifiers to NSEvent.ModifierFlags
        let flags = NSEvent.ModifierFlags(rawValue: UInt(shortcutModifiers))
        var carbonMods: UInt32 = 0
        if flags.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if flags.contains(.option) { carbonMods |= UInt32(optionKey) }
        if flags.contains(.control) { carbonMods |= UInt32(controlKey) }
        if flags.contains(.shift) { carbonMods |= UInt32(shiftKey) }

        hotKey = HotKey(carbonKeyCode: UInt32(shortcutKeyCode), carbonModifiers: carbonMods)
        hotKey?.keyDownHandler = { [weak self] in
            self?.toggleOverlay()
        }
    }

    private func setupCapture() {
        captureManager = ScreenCaptureManager()

        Task { @MainActor in
            // Initialize frame buffer (loads persisted frames from disk)
            do {
                let buffer = try await FrameBuffer()
                frameBuffer = buffer

                let loadedCount = buffer.frameCount
                if loadedCount > 0 {
                    print("Loaded \(loadedCount) frames from disk")
                }
            } catch {
                print("Failed to initialize frame buffer: \(error)")
                // Show error but don't quit
                showErrorAlert(error)
                return
            }

            captureManager.delegate = self
            let preflightPolicy = computeCapturePolicy()
            captureManager.updateCaptureInterval(preflightPolicy.interval)
            captureManager.updateCaptureScale(preflightPolicy.scale)
            frameBuffer?.updateSaveOptions(
                preflightPolicy.saveOptions,
                duplicatePolicy: preflightPolicy.duplicatePolicy
            )

            do {
                try await captureManager.startCapture()
                updateCaptureStatus("Active")
                lastAppliedPolicy = nil
                updateCapturePolicy()
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
        // Re-evaluate capture policy periodically (battery, idle, thermal)
        capturePolicyTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { [weak self] _ in
            self?.updateCapturePolicy()
        }
        capturePolicyTimer?.tolerance = 5.0
    }

    private func setupObservers() {
        userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateCapturePolicy()
        }

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateCapturePolicy()
        }
    }

    private func setupSleepWakeObservers() {
        let workspace = NSWorkspace.shared.notificationCenter

        // System sleep/wake
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

        // Screen sleep/wake (display off while computer still running)
        workspace.addObserver(
            self,
            selector: #selector(handleScreenSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )

        workspace.addObserver(
            self,
            selector: #selector(handleScreenWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
    }

    @objc private func handleSleep() {
        Task { @MainActor in
            updateCaptureStatus("Sleeping...")
            await captureManager.stopCapture()
            appNapPreventer.stopActivity()
            print("Capture paused for system sleep")
        }
    }

    @objc private func handleWake() {
        frameBuffer?.enableBlackFrameFilter(for: 5)
        resumeCapture(reason: "system wake")
    }

    @objc private func handleScreenSleep() {
        Task { @MainActor in
            updateCaptureStatus("Screen Off")
            await captureManager.stopCapture()
            appNapPreventer.stopActivity()
            print("Capture paused for screen sleep")
        }
    }

    @objc private func handleScreenWake() {
        frameBuffer?.enableBlackFrameFilter(for: 5)
        resumeCapture(reason: "screen wake")
    }

    private func resumeCapture(reason: String) {
        Task { @MainActor in
            guard overlayController?.isVisible != true else {
                updateCaptureStatus("Paused (Overlay)")
                return
            }

            updateCaptureStatus("Resuming...")

            // Delay to let system stabilise
            try? await Task.sleep(for: .seconds(2))

            do {
                try await captureManager.startCapture()
                updateCaptureStatus("Active")
                lastAppliedPolicy = nil
                updateCapturePolicy()
                print("Capture resumed after \(reason)")
            } catch {
                print("Failed to resume capture after \(reason): \(error)")
                updateCaptureStatus("Error")

                // Retry once more after another delay
                try? await Task.sleep(for: .seconds(3))
                do {
                    try await captureManager.startCapture()
                    updateCaptureStatus("Active")
                    lastAppliedPolicy = nil
                    updateCapturePolicy()
                    print("Capture resumed on retry")
                } catch {
                    print("Retry also failed: \(error)")
                    updateCaptureStatus("Failed")
                }
            }
        }
    }

    // MARK: - Capture Delegate

    func captureManager(_ manager: ScreenCaptureManager, didCaptureFrame image: CGImage, at timestamp: Date) {
        frameBuffer?.addFrame(image, timestamp: timestamp)
    }

    func captureManagerDidStop(_ manager: ScreenCaptureManager) {
        guard overlayController?.isVisible != true, !isPausedForOverlay else { return }
        print("Capture stopped unexpectedly, attempting restart...")
        updateCaptureStatus("Restarting...")
        appNapPreventer.stopActivity()

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))

            do {
                try await captureManager.startCapture()
                updateCaptureStatus("Active")
                lastAppliedPolicy = nil
                updateCapturePolicy()
                print("Capture restarted successfully")
            } catch {
                print("Failed to restart capture: \(error)")
                updateCaptureStatus("Stopped")
            }
        }
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
        guard let frameBuffer = frameBuffer else { return }

        Task { @MainActor in
            // Capture a fresh frame immediately so the overlay has the latest state
            if let image = await captureManager.captureNow() {
                await frameBuffer.addFrameSync(image, timestamp: Date())
            }

            if overlayController == nil {
                overlayController = OverlayWindowController(
                    frameBuffer: frameBuffer,
                    onVisibilityChanged: { [weak self] isVisible in
                        self?.handleOverlayVisibilityChanged(isVisible: isVisible)
                    }
                )
            }
            overlayController?.showOverlay()
        }
    }

    private func handleOverlayVisibilityChanged(isVisible: Bool) {
        if isVisible {
            pauseCaptureForOverlay()
        } else {
            resumeCaptureAfterOverlay()
        }
    }

    private func pauseCaptureForOverlay() {
        guard !isPausedForOverlay else { return }
        isPausedForOverlay = true
        wasCapturingBeforeOverlay = captureManager.isCapturing

        guard wasCapturingBeforeOverlay else { return }
        Task { @MainActor in
            updateCaptureStatus("Paused (Overlay)")
            await captureManager.stopCapture()
            appNapPreventer.stopActivity()
        }
    }

    private func resumeCaptureAfterOverlay() {
        guard isPausedForOverlay else { return }
        isPausedForOverlay = false
        guard wasCapturingBeforeOverlay else { return }
        wasCapturingBeforeOverlay = false

        Task { @MainActor in
            updateCaptureStatus("Resuming...")
            do {
                try await captureManager.startCapture()
                updateCaptureStatus("Active")
                lastAppliedPolicy = nil
                updateCapturePolicy()
            } catch {
                updateCaptureStatus("Error")
                print("Failed to resume capture after overlay: \(error)")
            }
        }
    }

    @objc private func showSettings() {
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 450),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "JustNow Settings"
        window.contentView = NSHostingView(rootView: SettingsView(
            frameBuffer: frameBuffer,
            onShortcutChanged: { [weak self] in
                self?.registerHotKey()
            }
        ))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        updateFrameCountMenuItem()
    }

    // MARK: - Helpers

    private func updateCapturePolicy() {
        guard captureManager != nil else { return }
        let policy = computeCapturePolicy()
        guard policy != lastAppliedPolicy else { return }
        lastAppliedPolicy = policy

        captureManager.updateCaptureInterval(policy.interval)
        captureManager.updateCaptureScale(policy.scale)
        frameBuffer?.updateSaveOptions(policy.saveOptions, duplicatePolicy: policy.duplicatePolicy)

        if captureManager.isCapturing {
            if policy.shouldPreventAppNap {
                appNapPreventer.startActivity()
            } else {
                appNapPreventer.stopActivity()
            }
        }
    }

    private func computeCapturePolicy() -> CapturePolicy {
        let adaptiveEnabled = reduceCaptureOnBattery
        let onBattery = adaptiveEnabled && PowerManager.isOnBattery()
        let lowPowerMode = adaptiveEnabled && ProcessInfo.processInfo.isLowPowerModeEnabled
        let idleDuration = secondsSinceLastUserEvent()
        let isIdle = adaptiveEnabled && idleDuration >= idleThreshold
        let thermalState = ProcessInfo.processInfo.thermalState
        let isThermalConstrained = adaptiveEnabled && (thermalState == .serious || thermalState == .critical)

        var interval = captureInterval
        var scale = 2
        var saveOptions = FrameSaveOptions.standard
        var duplicatePolicy = DuplicateFramePolicy.standard

        if onBattery || lowPowerMode {
            interval *= batteryMultiplier
            scale = 1
            saveOptions = .lowPower
            duplicatePolicy = .lowPower
        }

        if isIdle {
            interval *= idleMultiplier
            saveOptions = .lowPower
            duplicatePolicy = .lowPower
        }

        if isThermalConstrained {
            let multiplier = (thermalState == .critical) ? thermalCriticalMultiplier : thermalSeriousMultiplier
            interval *= multiplier
            scale = 1
            saveOptions = .lowPower
            duplicatePolicy = .lowPower
        }

        interval = min(interval, maxCaptureInterval)

        let allowAppNap = onBattery || lowPowerMode || isIdle || isThermalConstrained || interval >= 5
        let shouldPreventAppNap = !allowAppNap

        return CapturePolicy(
            interval: interval,
            scale: scale,
            saveOptions: saveOptions,
            duplicatePolicy: duplicatePolicy,
            shouldPreventAppNap: shouldPreventAppNap
        )
    }

    private func secondsSinceLastUserEvent() -> TimeInterval {
        let anyEventType = CGEventType(rawValue: UInt32.max)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEventType)
    }

    private func updateFrameCountMenuItem() {
        guard let menu = statusItem.menu else { return }

        if let item = menu.item(withTag: 100) {
            let count = frameBuffer?.frameCount ?? 0
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
