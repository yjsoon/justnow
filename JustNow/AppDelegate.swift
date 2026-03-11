//
//  AppDelegate.swift
//  JustNow
//

import AppKit
import CoreGraphics
import SwiftUI
import HotKey
import Carbon.HIToolbox
import Sparkle

enum RecentTimelineWindow: Double, CaseIterable, Identifiable {
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300
    case tenMinutes = 600

    static let defaultValue: Self = .fiveMinutes

    var id: Double { rawValue }

    var timeInterval: TimeInterval { rawValue }

    var label: String {
        switch self {
        case .oneMinute:
            return "1 min"
        case .twoMinutes:
            return "2 min"
        case .fiveMinutes:
            return "5 min"
        case .tenMinutes:
            return "10 min"
        }
    }

    static func resolved(from rawValue: Double) -> Self {
        Self(rawValue: rawValue) ?? .defaultValue
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, ScreenCaptureDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var captureManager: ScreenCaptureManager!
    private var frameBuffer: FrameBuffer?
    private var overlayController: OverlayWindowController?
    private var hotKey: HotKey?
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var appNapPreventer = AppNapPreventer()
    private let launchAtLoginManager = LaunchAtLoginManager()
    private var settingsWindow: NSWindow?
    private lazy var settingsContext = SettingsContext(
        launchAtLoginManager: launchAtLoginManager,
        updater: updaterController.updater,
        onCheckForUpdates: { [weak self] in
            self?.checkForUpdates(nil)
        },
        onShortcutChanged: { [weak self] in
            self?.registerHotKey()
        }
    )

    @AppStorage("captureInterval") private var captureInterval: Double = 0.5
    @AppStorage("rewindHistorySeconds") private var rewindHistorySeconds: Double = RewindHistoryOption.defaultValue.rawValue
    @AppStorage("recentTimelineWindowSeconds")
    private var recentTimelineWindowSeconds: Double = RecentTimelineWindow.defaultValue.rawValue
    @AppStorage("reduceCaptureOnBattery") private var reduceCaptureOnBattery: Bool = true
    @AppStorage("keepConfiguredCaptureCadenceOnBattery")
    private var keepConfiguredCaptureCadenceOnBattery: Bool = true
    @AppStorage("backgroundSearchIndexingEnabled") private var backgroundSearchIndexingEnabled: Bool = true
    @AppStorage("shortcutKeyCode") private var shortcutKeyCode: Int = 38  // J key
    @AppStorage("shortcutModifiers") private var shortcutModifiers: Int = 1_572_864  // ⌘⌥
    @AppStorage("overlayDismissKeyCode") private var overlayDismissKeyCode: Int = 53
    @AppStorage("overlayDismissModifiers") private var overlayDismissModifiers: Int = 0
    @AppStorage("hasRequestedScreenRecordingPermission")
    private var hasRequestedScreenRecordingPermission = false

    private var capturePolicyTimer: Timer?
    private var userDefaultsObserver: NSObjectProtocol?
    private var thermalObserver: NSObjectProtocol?
    private var inputEventMonitor: Any?
    private var lastAppliedPolicy: CapturePolicy?
    private var lastUserActivityUpdate: Date = .distantPast
    private var isUserPaused = false
    private var wasCapturingBeforeOverlay = false
    private var isPausedForOverlay = false
    private var wasCapturingBeforeSession = false
    private var isPausedForSession = false
    private var idleTransitionTimer: Timer?
    private var didRequestScreenRecordingPermissionThisLaunch = false
    private var didShowPermissionAlertThisLaunch = false
    private var didShowPermissionRestartAlertThisLaunch = false
    private var permissionPromptFollowUpTask: Task<Void, Never>?

    private let idleThreshold: TimeInterval = 60
    private let inputPolicyUpdateInterval: TimeInterval = 1
    private let idleMultiplier: Double = 4
    private let batteryMultiplier: Double = 3
    private let batteryLowThreshold: Double = 0.3
    private let batteryCriticalThreshold: Double = 0.15
    private let batteryLowMultiplier: Double = 1.5
    private let batteryCriticalMultiplier: Double = 2
    private let thermalSeriousMultiplier: Double = 2
    private let thermalCriticalMultiplier: Double = 4
    private let maxCaptureInterval: Double = 30
    private let ocrIndexBaseInterval: TimeInterval = 2.5
    private let ocrIndexBatteryInterval: TimeInterval = 10
    private let ocrIndexIdleInterval: TimeInterval = 15
    private let ocrIndexThermalSeriousInterval: TimeInterval = 20
    private let ocrIndexMaxFrameAge: TimeInterval = 5 * 60
    private let ocrIndexBatteryMaxFrameAge: TimeInterval = 3 * 60
    private let ocrIndexBaseQueueDepth: Int = 120
    private let ocrIndexBatteryQueueDepth: Int = 60
    private let ocrIndexIdleQueueDepth: Int = 40
    private let ocrIndexThermalQueueDepth: Int = 24

    private struct CapturePolicy: Equatable {
        let interval: TimeInterval
        let scale: Int
        let saveOptions: FrameSaveOptions
        let duplicatePolicy: DuplicateFramePolicy
        let ocrIndexingPolicy: OCRIndexingPolicy
        let shouldPreventAppNap: Bool
        let isIdle: Bool
    }

    private enum LaunchPermissionState {
        case granted
        case requestedThisLaunch
        case deniedPreviously
    }

    private enum MenuItemTag {
        static let frameCount = 100
        static let captureStatus = 101
        static let pauseToggle = 102
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        updaterController.startUpdater()
        setupHotKey()
        setupCapture()
        setupTimers()
        setupObservers()
        setupInputMonitor()
        setupSleepWakeObservers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appNapPreventer.stopActivity()
        capturePolicyTimer?.invalidate()
        idleTransitionTimer?.invalidate()
        permissionPromptFollowUpTask?.cancel()
        if let observer = userDefaultsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = thermalObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let monitor = inputEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        Task { @MainActor in
            await frameBuffer?.flushCaches()
        }
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItemButtonAppearance()

        let menu = NSMenu()

        let showItem = NSMenuItem(title: "Show Timeline", action: #selector(showOverlay), keyEquivalent: "")
        showItem.target = self
        showItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(showItem)

        let pauseItem = NSMenuItem(title: "Pause Recording", action: #selector(toggleCapturePause), keyEquivalent: "")
        pauseItem.target = self
        pauseItem.tag = MenuItemTag.pauseToggle
        menu.addItem(pauseItem)

        menu.addItem(NSMenuItem.separator())

        let frameCountItem = NSMenuItem(title: "Frames: 0", action: nil, keyEquivalent: "")
        frameCountItem.tag = MenuItemTag.frameCount
        frameCountItem.isEnabled = false
        menu.addItem(frameCountItem)

        let captureStatusItem = NSMenuItem(title: "Capture: Starting...", action: nil, keyEquivalent: "")
        captureStatusItem.tag = MenuItemTag.captureStatus
        captureStatusItem.isEnabled = false
        menu.addItem(captureStatusItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updatesItem.target = updaterController
        menu.addItem(updatesItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit JustNow", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
        updatePauseMenuItem()
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

    func makeSettingsView() -> SettingsView {
        SettingsView(context: settingsContext)
    }

    private func setupCapture() {
        captureManager = ScreenCaptureManager()

        Task { @MainActor in
            // Initialize frame buffer (loads persisted frames from disk)
            do {
                let buffer = try await FrameBuffer(retentionPolicy: currentRetentionPolicy())
                frameBuffer = buffer
                settingsContext.frameBuffer = buffer

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
            frameBuffer?.updateOCRIndexingPolicy(preflightPolicy.ocrIndexingPolicy)

            guard !isUserPaused else {
                updateCaptureStatus("Paused (User)")
                return
            }

            switch resolveLaunchPermissionState() {
            case .granted:
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
            case .requestedThisLaunch:
                updateCaptureStatus("Awaiting Permission")
            case .deniedPreviously:
                updateCaptureStatus("No Permission")
                showPermissionAlert()
            }
        }
    }

    private func setupTimers() {
        scheduleIdleTransitionCheck()

        // Re-evaluate capture policy periodically (battery, low power, thermal)
        capturePolicyTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateCapturePolicy()
            }
        }
        capturePolicyTimer?.tolerance = 10.0
    }

    private func setupObservers() {
        userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateCapturePolicy()
                if let self {
                    await self.frameBuffer?.updateRetentionPolicy(self.currentRetentionPolicy())
                }
            }
        }

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateCapturePolicy()
            }
        }
    }

    private func setupInputMonitor() {
        inputEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .mouseMoved]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleUserActivity()
            }
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

        // Session active/inactive (screen lock, fast user switching)
        workspace.addObserver(
            self,
            selector: #selector(handleSessionResignActive),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )

        workspace.addObserver(
            self,
            selector: #selector(handleSessionBecomeActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
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

    @objc private func handleSessionResignActive() {
        pauseCaptureForSession()
    }

    @objc private func handleSessionBecomeActive() {
        resumeCaptureAfterSession()
    }

    private func pauseCaptureForSession() {
        guard !isPausedForSession else { return }
        isPausedForSession = true
        wasCapturingBeforeSession = captureManager.isCapturing

        guard wasCapturingBeforeSession else { return }
        Task { @MainActor in
            updateCaptureStatus("Session Inactive")
            await captureManager.stopCapture()
            appNapPreventer.stopActivity()
        }
    }

    private func resumeCaptureAfterSession() {
        guard isPausedForSession else { return }
        isPausedForSession = false
        guard wasCapturingBeforeSession else { return }
        wasCapturingBeforeSession = false

        frameBuffer?.enableBlackFrameFilter(for: 5)
        resumeCapture(reason: "session active")
    }

    private func resumeCapture(reason: String) {
        Task { @MainActor in
            guard !isUserPaused else {
                updateCaptureStatus("Paused (User)")
                return
            }

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
        guard overlayController?.isVisible != true, !isPausedForOverlay, !isUserPaused else { return }
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

    @objc private func toggleCapturePause() {
        isUserPaused.toggle()
        updatePauseMenuItem()
        updateStatusItemButtonAppearance()

        guard captureManager != nil else {
            updateCaptureStatus(isUserPaused ? "Paused (User)" : "Starting...")
            return
        }

        if isUserPaused {
            Task { @MainActor in
                updateCaptureStatus("Paused (User)")
                await captureManager.stopCapture()
                appNapPreventer.stopActivity()
            }
            return
        }

        frameBuffer?.enableBlackFrameFilter(for: 2)
        resumeCapture(reason: "manual resume")
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
                    dismissShortcutKeyCode: overlayDismissKeyCode,
                    dismissShortcutModifiers: overlayDismissModifiers,
                    onVisibilityChanged: { [weak self] isVisible in
                        self?.handleOverlayVisibilityChanged(isVisible: isVisible)
                    }
                )
            } else {
                overlayController?.updateDismissShortcut(
                    keyCode: overlayDismissKeyCode,
                    modifiers: overlayDismissModifiers
                )
            }
            let recentTimelineWindow = RecentTimelineWindow.resolved(from: recentTimelineWindowSeconds)
            let rewindHistoryOption = RewindHistoryOption.resolved(from: rewindHistorySeconds)
            overlayController?.showOverlay(
                recentTimelineWindow: recentTimelineWindow.timeInterval,
                rewindHistoryOption: rewindHistoryOption
            )
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
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 680),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "JustNow Settings"
        window.contentView = NSHostingView(rootView: makeSettingsView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        updateFrameCountMenuItem()
        updatePauseMenuItem()
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
        frameBuffer?.updateOCRIndexingPolicy(policy.ocrIndexingPolicy)

        if captureManager.isCapturing {
            if policy.shouldPreventAppNap {
                appNapPreventer.startActivity()
            } else {
                appNapPreventer.stopActivity()
            }
        }
    }

    private func currentRetentionPolicy() -> RetentionPolicy {
        RewindHistoryOption.resolved(from: rewindHistorySeconds).retentionPolicy
    }

    private func computeCapturePolicy() -> CapturePolicy {
        let adaptiveEnabled = reduceCaptureOnBattery
        let onBattery = adaptiveEnabled && PowerManager.isOnBattery()
        let lowPowerMode = adaptiveEnabled && ProcessInfo.processInfo.isLowPowerModeEnabled
        let batteryCharge = onBattery ? PowerManager.batteryChargeFraction() : nil
        let idleDuration = secondsSinceLastUserEvent()
        let isIdle = adaptiveEnabled && idleDuration >= idleThreshold
        let thermalState = ProcessInfo.processInfo.thermalState
        let isThermalConstrained = adaptiveEnabled && (thermalState == .serious || thermalState == .critical)

        var interval = captureInterval
        var scale = 2
        var saveOptions = FrameSaveOptions.standard
        var duplicatePolicy = DuplicateFramePolicy.exact(atMostEvery: captureInterval)
        var ocrIndexEnabled = backgroundSearchIndexingEnabled
        var ocrIndexInterval = ocrIndexBaseInterval
        var ocrIndexQueueDepth = ocrIndexBaseQueueDepth
        var ocrIndexMaxAge = ocrIndexMaxFrameAge

        if onBattery || lowPowerMode {
            scale = 1
            saveOptions = .lowPower
            if !keepConfiguredCaptureCadenceOnBattery {
                interval *= batteryMultiplier
                duplicatePolicy = .lowPower
            }

            ocrIndexInterval = ocrIndexBatteryInterval
            ocrIndexQueueDepth = ocrIndexBatteryQueueDepth
            ocrIndexMaxAge = ocrIndexBatteryMaxFrameAge
        }

        if let batteryCharge {
            if batteryCharge <= batteryCriticalThreshold {
                scale = 1
                saveOptions = .lowPower
                if !keepConfiguredCaptureCadenceOnBattery {
                    interval *= batteryCriticalMultiplier
                    duplicatePolicy = .lowPower
                }
                ocrIndexEnabled = false
            } else if batteryCharge <= batteryLowThreshold {
                scale = 1
                saveOptions = .lowPower
                if !keepConfiguredCaptureCadenceOnBattery {
                    interval *= batteryLowMultiplier
                    duplicatePolicy = .lowPower
                }

                ocrIndexInterval = max(ocrIndexInterval, ocrIndexBatteryInterval)
                ocrIndexQueueDepth = min(ocrIndexQueueDepth, ocrIndexBatteryQueueDepth)
                ocrIndexMaxAge = min(ocrIndexMaxAge, ocrIndexBatteryMaxFrameAge)
            }
        }

        if isIdle {
            interval *= idleMultiplier
            scale = 1
            saveOptions = .lowPower
            duplicatePolicy = .lowPower

            ocrIndexInterval = max(ocrIndexInterval, ocrIndexIdleInterval)
            ocrIndexQueueDepth = min(ocrIndexQueueDepth, ocrIndexIdleQueueDepth)
        }

        if isThermalConstrained {
            let multiplier = (thermalState == .critical) ? thermalCriticalMultiplier : thermalSeriousMultiplier
            interval *= multiplier
            scale = 1
            saveOptions = .lowPower
            duplicatePolicy = .lowPower

            if thermalState == .critical {
                ocrIndexEnabled = false
            } else {
                ocrIndexInterval = max(ocrIndexInterval, ocrIndexThermalSeriousInterval)
                ocrIndexQueueDepth = min(ocrIndexQueueDepth, ocrIndexThermalQueueDepth)
                ocrIndexMaxAge = min(ocrIndexMaxAge, ocrIndexBatteryMaxFrameAge)
            }
        }

        interval = min(interval, maxCaptureInterval)

        let ocrPolicy = OCRIndexingPolicy(
            isEnabled: ocrIndexEnabled,
            minimumInterval: ocrIndexInterval,
            maxQueueDepth: ocrIndexQueueDepth,
            maxFrameAge: ocrIndexMaxAge
        )

        let batteryCanRelaxCadence = (onBattery || lowPowerMode) && !keepConfiguredCaptureCadenceOnBattery
        let allowAppNap = batteryCanRelaxCadence || isIdle || isThermalConstrained || interval >= 5
        let shouldPreventAppNap = !allowAppNap

        return CapturePolicy(
            interval: interval,
            scale: scale,
            saveOptions: saveOptions,
            duplicatePolicy: duplicatePolicy,
            ocrIndexingPolicy: ocrPolicy,
            shouldPreventAppNap: shouldPreventAppNap,
            isIdle: isIdle
        )
    }

    private func secondsSinceLastUserEvent() -> TimeInterval {
        let anyEventType = CGEventType(rawValue: UInt32.max)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEventType)
    }

    private func handleUserActivity() {
        let now = Date()
        guard now.timeIntervalSince(lastUserActivityUpdate) >= inputPolicyUpdateInterval else { return }
        lastUserActivityUpdate = now
        scheduleIdleTransitionCheck()

        guard lastAppliedPolicy?.isIdle == true else { return }
        updateCapturePolicy()
    }

    private func scheduleIdleTransitionCheck() {
        idleTransitionTimer?.invalidate()

        let idleDuration = secondsSinceLastUserEvent()
        let remaining = max(idleThreshold - idleDuration, 0)
        guard remaining > 0 else { return }

        idleTransitionTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.updateCapturePolicy()
            }
        }
        idleTransitionTimer?.tolerance = min(remaining * 0.2, 5.0)
    }

    private func updateFrameCountMenuItem() {
        guard let menu = statusItem.menu else { return }

        if let item = menu.item(withTag: MenuItemTag.frameCount) {
            let count = frameBuffer?.frameCount ?? 0
            item.title = "Frames: \(count)"
        }
    }

    private func updateCaptureStatus(_ status: String) {
        guard let menu = statusItem.menu,
              let item = menu.item(withTag: MenuItemTag.captureStatus) else { return }
        item.title = "Capture: \(status)"
    }

    private func updatePauseMenuItem() {
        guard let menu = statusItem.menu,
              let item = menu.item(withTag: MenuItemTag.pauseToggle) else { return }
        item.title = isUserPaused ? "Resume Recording" : "Pause Recording"
        item.state = isUserPaused ? .on : .off
    }

    private func updateStatusItemButtonAppearance() {
        guard let button = statusItem.button else { return }
        let accessibilityDescription = isUserPaused ? "JustNow (Paused)" : "JustNow"
        let assetName = isUserPaused ? "StatusBarIdle" : "StatusBarRecording"

        if let image = NSImage(named: assetName)?.copy() as? NSImage {
            image.isTemplate = true
            image.accessibilityDescription = accessibilityDescription
            button.image = image
        } else {
            button.image = NSImage(
                systemSymbolName: "clock.arrow.circlepath",
                accessibilityDescription: accessibilityDescription
            )
            button.image?.isTemplate = true
        }

        button.imagePosition = .imageOnly
        button.title = ""
    }

    private func resolveLaunchPermissionState() -> LaunchPermissionState {
        if ScreenCaptureManager.hasScreenRecordingPermission() {
            return .granted
        }

        if hasRequestedScreenRecordingPermission {
            return .deniedPreviously
        }

        guard !didRequestScreenRecordingPermissionThisLaunch else {
            return .deniedPreviously
        }

        didRequestScreenRecordingPermissionThisLaunch = true
        hasRequestedScreenRecordingPermission = true
        if ScreenCaptureManager.requestScreenRecordingPermission() {
            return .granted
        }

        schedulePermissionPromptFollowUp()
        return .requestedThisLaunch
    }

    private func schedulePermissionPromptFollowUp() {
        permissionPromptFollowUpTask?.cancel()
        permissionPromptFollowUpTask = Task { @MainActor [weak self] in
            guard let self else { return }

            if NSApp.isActive {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                guard didRequestScreenRecordingPermissionThisLaunch else { return }
                handlePermissionPromptResolution()
                return
            }

            let becameActiveNotifications = NotificationCenter.default.notifications(
                named: NSApplication.didBecomeActiveNotification,
                object: NSApp
            )

            for await _ in becameActiveNotifications {
                guard !Task.isCancelled else { return }
                guard didRequestScreenRecordingPermissionThisLaunch else { return }
                handlePermissionPromptResolution()
                return
            }
        }
    }

    private func handlePermissionPromptResolution() {
        if ScreenCaptureManager.hasScreenRecordingPermission() {
            updateCaptureStatus("Restart Required")
            showPermissionRestartAlert()
        } else {
            updateCaptureStatus("No Permission")
            showPermissionAlert()
        }
    }

    private func showPermissionAlert() {
        guard !didShowPermissionAlertThisLaunch else { return }
        didShowPermissionAlertThisLaunch = true

        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = """
        JustNow needs Screen Recording permission to capture your screen history.

        Open System Settings → Privacy & Security → Screen Recording and allow JustNow.

        After enabling JustNow, quit and reopen the app once so capture can restart cleanly with the new permission.

        If JustNow is already enabled there but capture still fails after a recent build, signing, or notarisation change, remove the JustNow entry from Screen Recording and relaunch once so macOS can create a fresh permission record.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")

        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return
        }

        NSApp.terminate(nil)
    }

    private func showPermissionRestartAlert() {
        guard !didShowPermissionRestartAlertThisLaunch else { return }
        didShowPermissionRestartAlertThisLaunch = true

        let alert = NSAlert()
        alert.messageText = "Restart JustNow to Start Capture"
        alert.informativeText = """
        Screen Recording is now enabled for JustNow.

        Quit and reopen the app once so capture can restart cleanly with the new permission.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Quit JustNow")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
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
