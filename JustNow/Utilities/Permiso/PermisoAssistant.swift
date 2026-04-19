// Adapted from https://github.com/zats/permiso. See ATTRIBUTION.md in this directory.

import AppKit
import Foundation

@MainActor
final class PermisoAssistant {
    static let shared = PermisoAssistant()

    private var overlayController: PermisoOverlayWindowController?
    private var trackingTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var activePanel: PermisoPanel?
    private var pendingSourceFrameInScreen: CGRect?
    private var didPresentCurrentOverlay = false

    init() {}

    var isPresenting: Bool {
        overlayController?.window?.isVisible == true
    }

    func present(
        panel: PermisoPanel,
        hostApp: PermisoHostApp = .current(),
        sourceFrameInScreen: CGRect? = nil
    ) {
        dismiss()

        activePanel = panel
        pendingSourceFrameInScreen = sourceFrameInScreen
        didPresentCurrentOverlay = false
        overlayController = PermisoOverlayWindowController(hostApp: hostApp, panel: panel) { [weak self] in
            self?.dismiss()
        }
        NSWorkspace.shared.open(panel.settingsURL)
        startTracking()
    }

    func dismiss() {
        pausePolling()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        overlayController?.close()
        overlayController = nil
        activePanel = nil
        pendingSourceFrameInScreen = nil
        didPresentCurrentOverlay = false
    }

    private func startTracking() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        // Watching app activation lets us wake the polling timer when the user returns
        // to System Settings without paying the idle-CPU cost of a 150ms poll while
        // Settings isn't frontmost.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPosition()
            }
        }
        refreshPosition()
    }

    private func refreshPosition() {
        guard SettingsWindowLocator.isSystemSettingsFrontmost else {
            pausePolling()
            overlayController?.hide()
            return
        }

        // Settings is frontmost — ensure the poll is running even before we have a
        // window snapshot. When the user launches Settings from cold, the activation
        // notification fires before the window is registered with CGWindowList, so we
        // need the timer to retry until the window shows up.
        ensurePolling()

        guard let snapshot = SettingsWindowLocator.frontmostWindow() else {
            // Settings is frontmost but has no matching window (either still spinning
            // up or the user just closed its last window). Keep polling so we catch
            // the window when it appears, but hide the coach so it doesn't stay parked
            // at its previous position over an empty desktop.
            overlayController?.hide()
            return
        }

        if didPresentCurrentOverlay {
            overlayController?.updatePosition(with: snapshot.frame, visibleFrame: snapshot.visibleFrame)
            return
        }

        overlayController?.present(
            from: pendingSourceFrameInScreen,
            settingsFrame: snapshot.frame,
            visibleFrame: snapshot.visibleFrame
        )
        didPresentCurrentOverlay = true
    }

    private func ensurePolling() {
        guard trackingTimer == nil else { return }
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPosition()
            }
        }
    }

    private func pausePolling() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }
}
