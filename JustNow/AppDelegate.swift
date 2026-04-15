//
//  AppDelegate.swift
//  JustNow
//

import AppKit
import CoreGraphics
import SwiftUI
import Sparkle

enum FeatureFlags {
    /// Temporary kill switch while in-app search is hidden from release builds.
    static let isSearchEnabled = true
}

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
class AppDelegate: NSObject, NSApplicationDelegate, ScreenCaptureDelegate {
    private var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private var statusItemController: StatusItemController!
    private var captureManager: ScreenCaptureManager!
    private var frameBuffer: FrameBuffer?
    private var overlayController: OverlayWindowController?
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private lazy var hotKeyController = HotKeyController(
        overlayHandler: { [weak self] in
            self?.toggleOverlay()
        },
        capturePauseHandler: { [weak self] in
            self?.toggleCapturePause()
        }
    )
    private var appNapPreventer = AppNapPreventer()
    private let launchAtLoginManager = LaunchAtLoginManager()
    private lazy var settingsContext = SettingsContext(
        launchAtLoginManager: launchAtLoginManager,
        updater: updaterController.updater,
        onCheckForUpdates: { [weak self] in
            self?.checkForUpdates(nil)
        },
        onShortcutChanged: { [weak self] in
            self?.keyboardShortcutsDidChange()
        }
    )
    private lazy var settingsWindowCoordinator = SettingsWindowCoordinator(
        makeContentView: { [weak self] in
            guard let self else {
                return NSView()
            }

            return NSHostingView(rootView: self.makeSettingsView())
        }
    )

    @AppStorage(AppStorageKey.captureInterval) private var captureInterval: Double = AppStorageDefault.captureInterval
    @AppStorage(AppStorageKey.rewindHistorySeconds) private var rewindHistorySeconds: Double = AppStorageDefault.rewindHistorySeconds
    @AppStorage(AppStorageKey.recentTimelineWindowSeconds)
    private var recentTimelineWindowSeconds: Double = AppStorageDefault.recentTimelineWindowSeconds
    @AppStorage(AppStorageKey.reduceCaptureOnBattery) private var reduceCaptureOnBattery: Bool = AppStorageDefault.reduceCaptureOnBattery
    @AppStorage(AppStorageKey.shortcutKeyCode) private var shortcutKeyCode: Int = AppStorageDefault.shortcutKeyCode
    @AppStorage(AppStorageKey.shortcutModifiers) private var shortcutModifiers: Int = AppStorageDefault.shortcutModifiers
    @AppStorage(AppStorageKey.capturePauseShortcutKeyCode) private var capturePauseShortcutKeyCode: Int = AppStorageDefault.capturePauseShortcutKeyCode
    @AppStorage(AppStorageKey.capturePauseShortcutModifiers) private var capturePauseShortcutModifiers: Int = AppStorageDefault.capturePauseShortcutModifiers
    @AppStorage(AppStorageKey.overlayDismissKeyCode) private var overlayDismissKeyCode: Int = AppStorageDefault.overlayDismissKeyCode
    @AppStorage(AppStorageKey.overlayDismissModifiers) private var overlayDismissModifiers: Int = AppStorageDefault.overlayDismissModifiers
    private var capturePolicyTimer: Timer?
    private var userDefaultsObserver: NSObjectProtocol?
    private var thermalObserver: NSObjectProtocol?
    private var inputEventMonitor: Any?
    private var lastAppliedRetentionPolicy: RetentionPolicy?
    private var overlayPresentationTask: Task<Void, Never>?
    private var setupCaptureTask: Task<Void, Never>?
    private var isTerminationFlushInProgress = false
    private var idleTransitionTimer: Timer?
    private var screenRecordingPermission = ScreenRecordingPermissionState()
    private let capturePolicyController = CapturePolicyController()
    private let captureStartController = CaptureStartController()
    private lazy var captureStopController = CaptureStopController(
        updateStatus: { [weak self] in self?.updateCaptureStatus($0) },
        stopCapture: { [weak self] in
            await self?.captureManager.stopCapture()
        },
        endForegroundActivity: { [weak self] in
            self?.appNapPreventer.stopActivity()
        }
    )
    private lazy var captureEventController = CaptureEventController(
        context: { [weak self] in
            guard let self else {
                return CaptureEventContext(
                    hasCaptureManager: false,
                    isCapturing: false,
                    isSetupCaptureInProgress: false,
                    hasPendingStart: false,
                    isOverlayVisible: false
                )
            }

            return CaptureEventContext(
                hasCaptureManager: self.captureManager != nil,
                isCapturing: self.captureManager?.isCapturing == true,
                isSetupCaptureInProgress: self.setupCaptureTask != nil,
                hasPendingStart: self.captureStartController.hasPendingStart,
                isOverlayVisible: self.isOverlayVisible
            )
        },
        scheduleStart: { [weak self] in self?.scheduleCaptureStart($0) },
        cancelPendingStart: { [weak self] in self?.captureStartController.cancelPendingStart() },
        scheduleStop: { [weak self] in self?.captureStopController.scheduleStop($0) },
        updateStatus: { [weak self] in self?.updateCaptureStatus($0) },
        enableBlackFrameFilter: { [weak self] in self?.frameBuffer?.enableBlackFrameFilter(for: $0) },
        endForegroundActivity: { [weak self] in self?.appNapPreventer.stopActivity() },
        updatePauseMenu: { [weak self] isPaused in self?.statusItemController?.setPaused(isPaused) }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningUnderXCTest else { return }

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
        if let observer = userDefaultsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = thermalObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let monitor = inputEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminationFlushInProgress else { return .terminateLater }

        isTerminationFlushInProgress = true
        overlayPresentationTask?.cancel()
        setupCaptureTask?.cancel()
        captureStartController.cancelPendingStart()

        Task { @MainActor [weak self] in
            guard let self else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }

            defer {
                self.isTerminationFlushInProgress = false
                sender.reply(toApplicationShouldTerminate: true)
            }

            await self.setupCaptureTask?.value
            await self.captureManager?.stopCapture()
            await self.frameBuffer?.flushCaches()
        }

        return .terminateLater
    }

    func applicationDidResignActive(_ notification: Notification) {
        screenRecordingPermission.noteApplicationDidResignActive()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        handlePendingPermissionPromptResolutionIfNeeded()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItemController = StatusItemController(
            actions: StatusItemControllerActions(
                showTimeline: { [weak self] in self?.showOverlay() },
                toggleCapturePause: { [weak self] in self?.toggleCapturePause() },
                showSettings: { [weak self] in self?.showSettings() },
                checkForUpdates: { [weak self] in self?.checkForUpdates(nil) },
                quitApp: { [weak self] in self?.quitApp() },
                showScreenRecordingHelp: { [weak self] in self?.showScreenRecordingHelp() },
                menuWillOpen: { [weak self] in self?.handleStatusMenuWillOpen() }
            )
        )
    }

    private func setupHotKey() {
        registerHotKeys()
    }

    private func keyboardShortcutsDidChange() {
        registerHotKeys()
        overlayController?.updateDismissShortcut(
            keyCode: overlayDismissKeyCode,
            modifiers: overlayDismissModifiers
        )
    }

    private func registerHotKeys() {
        hotKeyController.register(configuration: currentHotKeyConfiguration())
    }

    func makeSettingsView() -> SettingsView {
        SettingsView(context: settingsContext)
    }

    private func setupCapture() {
        captureManager = ScreenCaptureManager()

        setupCaptureTask?.cancel()
        setupCaptureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.setupCaptureTask = nil }

            // Initialize frame buffer (loads persisted frames from disk)
            do {
                let retentionPolicy = self.currentRetentionPolicy()
                let buffer = try await FrameBuffer(retentionPolicy: retentionPolicy)
                guard !Task.isCancelled else { return }

                self.frameBuffer = buffer
                self.lastAppliedRetentionPolicy = retentionPolicy
                self.settingsContext.frameBuffer = buffer

                let loadedCount = buffer.frameCount
                if loadedCount > 0 {
                    print("Loaded \(loadedCount) frames from disk")
                }
            } catch {
                if error is CancellationError || Task.isCancelled {
                    return
                }
                print("Failed to initialize frame buffer: \(error)")
                // Show error but don't quit
                self.showErrorAlert(error)
                return
            }

            guard !Task.isCancelled else { return }

            self.captureManager.delegate = self
            let preflightPolicy = self.currentCapturePolicy()
            self.captureManager.updateCaptureInterval(preflightPolicy.interval)
            self.captureManager.updateCaptureScale(preflightPolicy.scale)
            self.frameBuffer?.updateSaveOptions(
                preflightPolicy.saveOptions,
                duplicatePolicy: preflightPolicy.duplicatePolicy
            )
            self.frameBuffer?.updateOCRIndexingPolicy(preflightPolicy.ocrIndexingPolicy)

            guard self.captureEventController.canStartCapture() else {
                if let blockedStatus = self.captureEventController.blockedStatus() {
                    self.updateCaptureStatus(blockedStatus)
                }
                return
            }

            switch self.resolveLaunchPermissionState() {
            case .granted:
                do {
                    try await self.captureManager.startCapture()
                    guard !Task.isCancelled else { return }
                    guard self.captureEventController.canStartCapture() else {
                        await self.captureManager.stopCapture()
                        if let blockedStatus = self.captureEventController.blockedStatus() {
                            self.updateCaptureStatus(blockedStatus)
                        }
                        return
                    }
                    self.updateCaptureStatus("Active")
                    self.capturePolicyController.resetAppliedPolicy()
                    self.updateCapturePolicy()
                } catch is CancellationError {
                    return
                } catch CaptureError.permissionDenied {
                    self.updateCaptureStatus("No Permission")
                    self.showPermissionAlert()
                } catch {
                    self.updateCaptureStatus("Error")
                    self.showErrorAlert(error)
                }
            case .requestedThisLaunch:
                self.updateCaptureStatus("Awaiting Permission")
            case .deniedPreviously:
                self.updateCaptureStatus("No Permission")
                self.showPermissionAlert()
            }
        }
    }

    private func setupTimers() {
        scheduleIdleTransitionCheck()

        // Re-evaluate capture policy periodically (battery, low power, thermal)
        capturePolicyTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.updateCapturePolicy()
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
            guard let self else { return }
            Task { @MainActor [self] in
                self.updateCapturePolicy()
                await self.updateRetentionPolicyIfNeeded()
            }
        }

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.updateCapturePolicy()
            }
        }
    }

    private func setupInputMonitor() {
        inputEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .mouseMoved]
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.handleUserActivity()
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
        captureEventController.handleSleep()
    }

    @objc private func handleWake() {
        captureEventController.handleWake()
    }

    @objc private func handleScreenSleep() {
        captureEventController.handleScreenSleep()
    }

    @objc private func handleScreenWake() {
        captureEventController.handleScreenWake()
    }

    @objc private func handleSessionResignActive() {
        captureEventController.handleSessionResignActive()
    }

    @objc private func handleSessionBecomeActive() {
        captureEventController.handleSessionBecomeActive()
    }

    private func startCaptureIfAllowed(successMessage: String, failurePrefix: String, failureStatus: String) async -> Bool {
        guard !Task.isCancelled, captureEventController.canStartCapture() else { return false }

        do {
            try await captureManager.startCapture()
            guard !Task.isCancelled,
                  captureEventController.canStartCapture() else {
                await captureManager.stopCapture()
                return false
            }
            updateCaptureStatus("Active")
            capturePolicyController.resetAppliedPolicy()
            updateCapturePolicy()
            print(successMessage)
            return true
        } catch is CancellationError {
            return false
        } catch CaptureError.permissionDenied {
            updateCaptureStatus("No Permission")
            showPermissionAlert()
            return false
        } catch {
            print("\(failurePrefix): \(error)")
            updateCaptureStatus(failureStatus)
            return false
        }
    }

    private func scheduleCaptureStart(_ request: CaptureStartRequest) {
        captureStartController.scheduleStart(
            request: request,
            canStartCapture: { [weak self] in
                guard let self else { return false }
                return self.captureEventController.canStartCapture()
            },
            blockedStatus: { [weak self] includeOverlay in
                guard let self else { return nil }
                return self.captureEventController.blockedStatus(includeOverlay: includeOverlay)
            },
            updateStatus: { [weak self] status in
                self?.updateCaptureStatus(status)
            },
            startCapture: { [weak self] attempt in
                guard let self else { return false }
                return await self.startCaptureIfAllowed(
                    successMessage: attempt.successMessage,
                    failurePrefix: attempt.failurePrefix,
                    failureStatus: attempt.failureStatus
                )
            }
        )
    }

    // MARK: - Capture Delegate

    func captureManager(_ manager: ScreenCaptureManager, didCaptureFrame image: CGImage, at timestamp: Date) {
        frameBuffer?.addFrame(image, timestamp: timestamp)
    }

    func captureManagerDidStop(_ manager: ScreenCaptureManager) {
        captureEventController.handleUnexpectedStop()
    }

    @objc private func toggleCapturePause() {
        captureEventController.toggleCapturePause()
    }

    // MARK: - Actions

    @objc private func toggleOverlay() {
        if let overlayPresentationTask {
            overlayPresentationTask.cancel()
            self.overlayPresentationTask = nil
        } else if let controller = overlayController, controller.isVisible {
            controller.hideOverlay()
        } else {
            showOverlay()
        }
    }

    @objc private func showOverlay() {
        guard let frameBuffer = frameBuffer else { return }
        guard overlayPresentationTask == nil else { return }

        overlayPresentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.overlayPresentationTask = nil }

            // Capture a fresh frame immediately so the overlay has the latest state
            if let image = await self.captureManager.captureNow() {
                guard !Task.isCancelled else { return }
                await frameBuffer.addFrameSync(image, timestamp: Date())
            }

            guard !Task.isCancelled else { return }

            if self.overlayController == nil {
                self.overlayController = OverlayWindowController(
                    frameBuffer: frameBuffer,
                    dismissShortcutKeyCode: self.overlayDismissKeyCode,
                    dismissShortcutModifiers: self.overlayDismissModifiers,
                    onVisibilityChanged: { [weak self] isVisible in
                        guard let self else { return }
                        self.captureEventController.handleOverlayVisibilityChanged(isVisible: isVisible)
                    }
                )
            } else {
                self.overlayController?.updateDismissShortcut(
                    keyCode: self.overlayDismissKeyCode,
                    modifiers: self.overlayDismissModifiers
                )
            }
            let recentTimelineWindow = RecentTimelineWindow.resolved(from: self.recentTimelineWindowSeconds)
            let rewindHistoryOption = RewindHistoryOption.resolved(from: self.rewindHistorySeconds)
            self.overlayController?.showOverlay(
                recentTimelineWindow: recentTimelineWindow.timeInterval,
                rewindHistoryOption: rewindHistoryOption
            )
        }
    }

    @objc private func showSettings() {
        settingsWindowCoordinator.show()
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func showScreenRecordingHelp() {
        showPermissionAlert(force: true)
    }

    private func handleStatusMenuWillOpen() {
        updateFrameCountMenuItem()
        updatePauseMenuItem()
        updatePermissionHelpMenuItem()
    }

    // MARK: - Helpers

    private var isOverlayVisible: Bool {
        overlayController?.isVisible == true
    }

    private func updateCapturePolicy() {
        guard captureManager != nil else { return }
        capturePolicyController.applyIfNeeded(
            settings: currentCapturePolicySettings(),
            environment: currentCapturePolicyEnvironment(),
            isCapturing: captureManager.isCapturing,
            applier: CapturePolicyApplier(
                updateCaptureInterval: { [weak self] in self?.captureManager.updateCaptureInterval($0) },
                updateCaptureScale: { [weak self] in self?.captureManager.updateCaptureScale($0) },
                updateFramePersistence: { [weak self] saveOptions, duplicatePolicy in
                    self?.frameBuffer?.updateSaveOptions(saveOptions, duplicatePolicy: duplicatePolicy)
                },
                updateOCRIndexingPolicy: { [weak self] in self?.frameBuffer?.updateOCRIndexingPolicy($0) },
                beginForegroundActivity: { [weak self] in self?.appNapPreventer.startActivity() },
                endForegroundActivity: { [weak self] in self?.appNapPreventer.stopActivity() }
            )
        )
    }

    private func updateRetentionPolicyIfNeeded() async {
        guard let frameBuffer else { return }
        let retentionPolicy = currentRetentionPolicy()
        guard retentionPolicy != lastAppliedRetentionPolicy else { return }
        lastAppliedRetentionPolicy = retentionPolicy
        await frameBuffer.updateRetentionPolicy(retentionPolicy)
    }

    private func currentRetentionPolicy() -> RetentionPolicy {
        RewindHistoryOption.resolved(from: rewindHistorySeconds).retentionPolicy
    }

    private func currentCapturePolicy() -> CapturePolicy {
        capturePolicyController.currentPolicy(
            settings: currentCapturePolicySettings(),
            environment: currentCapturePolicyEnvironment()
        )
    }

    private func secondsSinceLastUserEvent() -> TimeInterval {
        let anyEventType = CGEventType(rawValue: UInt32.max)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEventType)
    }

    private func handleUserActivity() {
        guard capturePolicyController.noteUserActivity() else {
            scheduleIdleTransitionCheck()
            return
        }
        scheduleIdleTransitionCheck()
        updateCapturePolicy()
    }

    private func scheduleIdleTransitionCheck() {
        idleTransitionTimer?.invalidate()

        guard let remaining = capturePolicyController.idleTransitionDelay(
            for: secondsSinceLastUserEvent()
        ) else { return }

        idleTransitionTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.updateCapturePolicy()
            }
        }
        idleTransitionTimer?.tolerance = min(remaining * 0.2, 5.0)
    }

    private func updateFrameCountMenuItem() {
        statusItemController?.setFrameCount(frameBuffer?.frameCount ?? 0)
    }

    private func updateCaptureStatus(_ status: String) {
        statusItemController?.setCaptureStatus(status)
    }

    private func updatePauseMenuItem() {
        statusItemController?.setPaused(captureEventController.isUserPaused)
    }

    private func currentHotKeyConfiguration() -> HotKeyConfiguration {
        HotKeyConfiguration(
            overlayKeyCode: shortcutKeyCode,
            overlayModifiers: shortcutModifiers,
            capturePauseKeyCode: capturePauseShortcutKeyCode,
            capturePauseModifiers: capturePauseShortcutModifiers,
            overlayDismissKeyCode: overlayDismissKeyCode,
            overlayDismissModifiers: overlayDismissModifiers
        )
    }

    private func currentCapturePolicySettings() -> CapturePolicySettings {
        CapturePolicySettings(
            captureInterval: captureInterval,
            reduceCaptureOnBattery: reduceCaptureOnBattery
        )
    }

    private func currentCapturePolicyEnvironment() -> CapturePolicyEnvironment {
        CapturePolicyEnvironment(
            isOnBattery: PowerManager.isOnBattery(),
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            batteryChargeFraction: PowerManager.batteryChargeFraction(),
            idleDuration: secondsSinceLastUserEvent(),
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }

    private func resolveLaunchPermissionState() -> ScreenRecordingPermissionLaunchState {
        screenRecordingPermission.resolveLaunchState(
            hasPermission: ScreenCaptureManager.hasScreenRecordingPermission(),
            requestPermission: ScreenCaptureManager.requestScreenRecordingPermission
        )
    }

    private func handlePendingPermissionPromptResolutionIfNeeded() {
        switch screenRecordingPermission.resolvePendingPrompt(
            hasPermission: ScreenCaptureManager.hasScreenRecordingPermission()
        ) {
        case .none:
            return
        case .showRestartAlert:
            updateCaptureStatus("Restart Required")
            showPermissionRestartAlert()
        case .showPermissionAlert:
            updateCaptureStatus("No Permission")
            showPermissionAlert()
        }
    }

    private func updatePermissionHelpMenuItem() {
        let needsPermissionHelp = !ScreenCaptureManager.hasScreenRecordingPermission()
        statusItemController?.setPermissionHelpVisible(needsPermissionHelp)
    }

    private func showPermissionAlert(force: Bool = false) {
        guard screenRecordingPermission.consumePermissionAlertPresentation(force: force) else { return }

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
        guard screenRecordingPermission.consumeRestartAlertPresentation() else { return }

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
