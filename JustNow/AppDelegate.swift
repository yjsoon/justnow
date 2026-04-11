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
    private var statusItemController: StatusItemController!
    private var captureManager: ScreenCaptureManager!
    private var frameBuffer: FrameBuffer?
    private var overlayController: OverlayWindowController?
    private var overlayHotKey: HotKey?
    private var capturePauseHotKey: HotKey?
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
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
    private var lastAppliedPolicy: CapturePolicy?
    private var lastAppliedRetentionPolicy: RetentionPolicy?
    private var lastUserActivityUpdate: Date = .distantPast
    private var captureLifecycle = CaptureLifecycleState()
    private var overlayPresentationTask: Task<Void, Never>?
    private var setupCaptureTask: Task<Void, Never>?
    private var pendingCaptureStartTask: Task<Void, Never>?
    private var pendingCaptureStartGeneration = 0
    private var isTerminationFlushInProgress = false
    private var idleTransitionTimer: Timer?
    private var screenRecordingPermission = ScreenRecordingPermissionState()

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
    private let ocrIndexBaseConcurrentJobs: Int = 3
    private let ocrIndexBatteryConcurrentJobs: Int = 2
    private let ocrIndexIdleConcurrentJobs: Int = 2
    private let ocrIndexThermalConcurrentJobs: Int = 1
    private let ocrIndexBaseImageMaxPixelSize: Int = 1_200
    private let ocrIndexBatteryImageMaxPixelSize: Int = 1_000
    private let ocrIndexIdleImageMaxPixelSize: Int = 900
    private let ocrIndexThermalImageMaxPixelSize: Int = 800

    private struct CapturePolicy: Equatable {
        let interval: TimeInterval
        let scale: Int
        let saveOptions: FrameSaveOptions
        let duplicatePolicy: DuplicateFramePolicy
        let ocrIndexingPolicy: OCRIndexingPolicy
        let shouldPreventAppNap: Bool
        let isIdle: Bool
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
        cancelPendingCaptureStart()

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
        registerHotKey()
    }

    private func keyboardShortcutsDidChange() {
        registerHotKey()
        overlayController?.updateDismissShortcut(
            keyCode: overlayDismissKeyCode,
            modifiers: overlayDismissModifiers
        )
    }

    func registerHotKey() {
        overlayHotKey = nil
        capturePauseHotKey = nil

        // Global Carbon hotkeys: at most one registration per key+modifier pair. Open rewind wins over pause
        // when they match. Pause is also skipped if it matches the close rewind shortcut, which is handled
        // locally while the overlay is open—otherwise both handlers could fire for one key press.
        overlayHotKey = makeHotKey(
            keyCode: shortcutKeyCode,
            modifiers: shortcutModifiers
        ) { [weak self] in
            self?.toggleOverlay()
        }

        guard capturePauseShortcutKeyCode != -1 else { return }

        if shortcutsConflict(
            capturePauseShortcutKeyCode,
            capturePauseShortcutModifiers,
            shortcutKeyCode,
            shortcutModifiers
        ) {
            print("Skipping pause hotkey registration because it matches the open rewind shortcut")
            return
        }

        if shortcutsConflict(
            capturePauseShortcutKeyCode,
            capturePauseShortcutModifiers,
            overlayDismissKeyCode,
            overlayDismissModifiers
        ) {
            print("Skipping pause hotkey registration because it matches the close rewind shortcut")
            return
        }

        capturePauseHotKey = makeHotKey(
            keyCode: capturePauseShortcutKeyCode,
            modifiers: capturePauseShortcutModifiers
        ) { [weak self] in
            self?.toggleCapturePause()
        }
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
            let preflightPolicy = self.computeCapturePolicy()
            self.captureManager.updateCaptureInterval(preflightPolicy.interval)
            self.captureManager.updateCaptureScale(preflightPolicy.scale)
            self.frameBuffer?.updateSaveOptions(
                preflightPolicy.saveOptions,
                duplicatePolicy: preflightPolicy.duplicatePolicy
            )
            self.frameBuffer?.updateOCRIndexingPolicy(preflightPolicy.ocrIndexingPolicy)

            guard self.captureLifecycle.canStartCapture(isOverlayVisible: self.isOverlayVisible) else {
                if let blockedStatus = self.captureLifecycle.blockedStatus(
                    isOverlayVisible: self.isOverlayVisible
                ) {
                    self.updateCaptureStatus(blockedStatus)
                }
                return
            }

            switch self.resolveLaunchPermissionState() {
            case .granted:
                do {
                    try await self.captureManager.startCapture()
                    guard !Task.isCancelled else { return }
                    guard self.captureLifecycle.canStartCapture(isOverlayVisible: self.isOverlayVisible) else {
                        await self.captureManager.stopCapture()
                        if let blockedStatus = self.captureLifecycle.blockedStatus(
                            isOverlayVisible: self.isOverlayVisible
                        ) {
                            self.updateCaptureStatus(blockedStatus)
                        }
                        return
                    }
                    self.updateCaptureStatus("Active")
                    self.lastAppliedPolicy = nil
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
        cancelPendingCaptureStart()
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
        cancelPendingCaptureStart()
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
        let wasActivelyCapturing = captureManager.isCapturing
        let shouldResumeCaptureAfterSession =
            captureManager.isCapturing
            || setupCaptureTask != nil
            || pendingCaptureStartTask != nil
            || (captureLifecycle.isPausedForOverlay && captureLifecycle.wasCapturingBeforeOverlay)
        let shouldStopCapture = captureLifecycle.pauseForSession(
            captureWasActive: wasActivelyCapturing,
            shouldResumeCapture: shouldResumeCaptureAfterSession
        )
        cancelPendingCaptureStart()

        guard shouldStopCapture else { return }
        Task { @MainActor in
            updateCaptureStatus("Session Inactive")
            await captureManager.stopCapture()
            appNapPreventer.stopActivity()
        }
    }

    private func resumeCaptureAfterSession() {
        guard captureLifecycle.resumeAfterSession() else { return }

        frameBuffer?.enableBlackFrameFilter(for: 5)
        resumeCapture(reason: "session active")
    }

    private func cancelPendingCaptureStart() {
        pendingCaptureStartGeneration += 1
        pendingCaptureStartTask?.cancel()
        pendingCaptureStartTask = nil
    }

    private func startCaptureIfAllowed(successMessage: String, failurePrefix: String, failureStatus: String) async -> Bool {
        guard !Task.isCancelled, captureLifecycle.canStartCapture(isOverlayVisible: isOverlayVisible) else { return false }

        do {
            try await captureManager.startCapture()
            guard !Task.isCancelled,
                  captureLifecycle.canStartCapture(isOverlayVisible: isOverlayVisible) else {
                await captureManager.stopCapture()
                return false
            }
            updateCaptureStatus("Active")
            lastAppliedPolicy = nil
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

    private struct CaptureStartRetry {
        let delay: Duration
        let successMessage: String
        let failurePrefix: String
        let failureStatus: String
    }

    private func scheduleCaptureStart(
        status: String,
        includeOverlayInBlockedStatus: Bool = true,
        initialDelay: Duration? = nil,
        successMessage: String,
        failurePrefix: String,
        failureStatus: String,
        retry: CaptureStartRetry? = nil
    ) {
        cancelPendingCaptureStart()
        let generation = pendingCaptureStartGeneration
        pendingCaptureStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == self.pendingCaptureStartGeneration {
                    self.pendingCaptureStartTask = nil
                }
            }

            guard self.captureLifecycle.canStartCapture(isOverlayVisible: self.isOverlayVisible) else {
                if let blockedStatus = self.captureLifecycle.blockedStatus(
                    isOverlayVisible: self.isOverlayVisible,
                    includeOverlay: includeOverlayInBlockedStatus
                ) {
                    self.updateCaptureStatus(blockedStatus)
                }
                return
            }

            self.updateCaptureStatus(status)

            if let initialDelay {
                try? await Task.sleep(for: initialDelay)
            }

            guard !Task.isCancelled,
                  generation == self.pendingCaptureStartGeneration,
                  self.captureLifecycle.canStartCapture(isOverlayVisible: self.isOverlayVisible) else {
                return
            }

            let didStart = await self.startCaptureIfAllowed(
                successMessage: successMessage,
                failurePrefix: failurePrefix,
                failureStatus: failureStatus
            )
            guard !didStart, let retry else { return }

            try? await Task.sleep(for: retry.delay)

            guard !Task.isCancelled,
                  generation == self.pendingCaptureStartGeneration,
                  self.captureLifecycle.canStartCapture(isOverlayVisible: self.isOverlayVisible) else {
                return
            }

            _ = await self.startCaptureIfAllowed(
                successMessage: retry.successMessage,
                failurePrefix: retry.failurePrefix,
                failureStatus: retry.failureStatus
            )
        }
    }

    private func resumeCapture(reason: String) {
        if setupCaptureTask != nil {
            cancelPendingCaptureStart()
            updateCaptureStatus(captureLifecycle.blockedStatus(isOverlayVisible: isOverlayVisible) ?? "Resuming...")
            return
        }

        scheduleCaptureStart(
            status: "Resuming...",
            initialDelay: .seconds(2),
            successMessage: "Capture resumed after \(reason)",
            failurePrefix: "Failed to resume capture after \(reason)",
            failureStatus: "Error",
            retry: CaptureStartRetry(
                delay: .seconds(3),
                successMessage: "Capture resumed on retry",
                failurePrefix: "Retry also failed",
                failureStatus: "Failed"
            )
        )
    }

    // MARK: - Capture Delegate

    func captureManager(_ manager: ScreenCaptureManager, didCaptureFrame image: CGImage, at timestamp: Date) {
        frameBuffer?.addFrame(image, timestamp: timestamp)
    }

    func captureManagerDidStop(_ manager: ScreenCaptureManager) {
        guard captureLifecycle.shouldRestartAfterUnexpectedStop(isOverlayVisible: isOverlayVisible) else { return }
        print("Capture stopped unexpectedly, attempting restart...")
        appNapPreventer.stopActivity()
        scheduleCaptureStart(
            status: "Restarting...",
            initialDelay: .seconds(2),
            successMessage: "Capture restarted successfully",
            failurePrefix: "Failed to restart capture",
            failureStatus: "Stopped"
        )
    }

    @objc private func toggleCapturePause() {
        let isUserPaused = captureLifecycle.toggleUserPause()
        updatePauseMenuItem()

        guard captureManager != nil else {
            updateCaptureStatus(isUserPaused ? "Paused (User)" : "Starting...")
            return
        }

        if isUserPaused {
            cancelPendingCaptureStart()
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
                        self?.handleOverlayVisibilityChanged(isVisible: isVisible)
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

    private func handleOverlayVisibilityChanged(isVisible: Bool) {
        if isVisible {
            pauseCaptureForOverlay()
        } else {
            resumeCaptureAfterOverlay()
        }
    }

    private func pauseCaptureForOverlay() {
        let wasActivelyCapturing = captureManager.isCapturing
        let shouldResumeCaptureAfterOverlay =
            captureManager.isCapturing
            || setupCaptureTask != nil
            || pendingCaptureStartTask != nil
            || (captureLifecycle.isPausedForSession && captureLifecycle.wasCapturingBeforeSession)
        let shouldStopCapture = captureLifecycle.pauseForOverlay(
            captureWasActive: wasActivelyCapturing,
            shouldResumeCapture: shouldResumeCaptureAfterOverlay
        )
        cancelPendingCaptureStart()

        guard shouldStopCapture else { return }
        Task { @MainActor in
            updateCaptureStatus("Paused (Overlay)")
            await captureManager.stopCapture()
            appNapPreventer.stopActivity()
        }
    }

    private func resumeCaptureAfterOverlay() {
        guard captureLifecycle.resumeAfterOverlay() else { return }

        if setupCaptureTask != nil {
            cancelPendingCaptureStart()
            updateCaptureStatus(
                captureLifecycle.blockedStatus(
                    isOverlayVisible: isOverlayVisible,
                    includeOverlay: false
                ) ?? "Resuming..."
            )
            return
        }

        scheduleCaptureStart(
            status: "Resuming...",
            includeOverlayInBlockedStatus: false,
            successMessage: "Capture resumed after overlay",
            failurePrefix: "Failed to resume capture after overlay",
            failureStatus: "Error"
        )
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
        var ocrIndexEnabled = true
        var ocrIndexInterval = ocrIndexBaseInterval
        var ocrIndexQueueDepth = ocrIndexBaseQueueDepth
        var ocrIndexMaxAge = ocrIndexMaxFrameAge
        var ocrIndexConcurrentJobs = ocrIndexBaseConcurrentJobs
        var ocrIndexImageMaxPixelSize = ocrIndexBaseImageMaxPixelSize

        if onBattery || lowPowerMode {
            scale = 1
            saveOptions = .lowPower
            interval *= batteryMultiplier
            duplicatePolicy = .lowPower

            ocrIndexInterval = ocrIndexBatteryInterval
            ocrIndexQueueDepth = ocrIndexBatteryQueueDepth
            ocrIndexMaxAge = ocrIndexBatteryMaxFrameAge
            ocrIndexConcurrentJobs = ocrIndexBatteryConcurrentJobs
            ocrIndexImageMaxPixelSize = ocrIndexBatteryImageMaxPixelSize
        }

        if let batteryCharge {
            if batteryCharge <= batteryCriticalThreshold {
                scale = 1
                saveOptions = .lowPower
                interval *= batteryCriticalMultiplier
                duplicatePolicy = .lowPower
                ocrIndexEnabled = false
            } else if batteryCharge <= batteryLowThreshold {
                scale = 1
                saveOptions = .lowPower
                interval *= batteryLowMultiplier
                duplicatePolicy = .lowPower

                ocrIndexInterval = max(ocrIndexInterval, ocrIndexBatteryInterval)
                ocrIndexQueueDepth = min(ocrIndexQueueDepth, ocrIndexBatteryQueueDepth)
                ocrIndexMaxAge = min(ocrIndexMaxAge, ocrIndexBatteryMaxFrameAge)
                ocrIndexConcurrentJobs = min(ocrIndexConcurrentJobs, ocrIndexBatteryConcurrentJobs)
                ocrIndexImageMaxPixelSize = min(ocrIndexImageMaxPixelSize, ocrIndexBatteryImageMaxPixelSize)
            }
        }

        if isIdle {
            interval *= idleMultiplier
            scale = 1
            saveOptions = .lowPower
            duplicatePolicy = .lowPower

            ocrIndexInterval = max(ocrIndexInterval, ocrIndexIdleInterval)
            ocrIndexQueueDepth = min(ocrIndexQueueDepth, ocrIndexIdleQueueDepth)
            ocrIndexConcurrentJobs = min(ocrIndexConcurrentJobs, ocrIndexIdleConcurrentJobs)
            ocrIndexImageMaxPixelSize = min(ocrIndexImageMaxPixelSize, ocrIndexIdleImageMaxPixelSize)
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
                ocrIndexConcurrentJobs = min(ocrIndexConcurrentJobs, ocrIndexThermalConcurrentJobs)
                ocrIndexImageMaxPixelSize = min(ocrIndexImageMaxPixelSize, ocrIndexThermalImageMaxPixelSize)
            }
        }

        interval = min(interval, maxCaptureInterval)

        let ocrPolicy = OCRIndexingPolicy(
            isEnabled: ocrIndexEnabled,
            minimumInterval: ocrIndexInterval,
            maxQueueDepth: ocrIndexQueueDepth,
            maxFrameAge: ocrIndexMaxAge,
            concurrentJobs: ocrIndexConcurrentJobs,
            searchImageMaxPixelSize: ocrIndexImageMaxPixelSize
        )

        let batteryCanRelaxCadence = onBattery || lowPowerMode
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
        statusItemController?.setPaused(captureLifecycle.isUserPaused)
    }

    private func makeHotKey(
        keyCode: Int,
        modifiers: Int,
        handler: @escaping () -> Void
    ) -> HotKey? {
        guard keyCode != -1 else { return nil }

        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        var carbonMods: UInt32 = 0
        if flags.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if flags.contains(.option) { carbonMods |= UInt32(optionKey) }
        if flags.contains(.control) { carbonMods |= UInt32(controlKey) }
        if flags.contains(.shift) { carbonMods |= UInt32(shiftKey) }

        let hotKey = HotKey(carbonKeyCode: UInt32(keyCode), carbonModifiers: carbonMods)
        hotKey.keyDownHandler = handler
        return hotKey
    }

    private func shortcutsConflict(_ lhsKeyCode: Int, _ lhsModifiers: Int, _ rhsKeyCode: Int, _ rhsModifiers: Int) -> Bool {
        lhsKeyCode != -1
            && rhsKeyCode != -1
            && lhsKeyCode == rhsKeyCode
            && lhsModifiers == rhsModifiers
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
