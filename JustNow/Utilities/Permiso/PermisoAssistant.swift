// Vendored from https://github.com/zats/permiso (MIT).

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
        overlayController != nil
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
        trackingTimer?.invalidate()
        trackingTimer = nil
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
        trackingTimer?.invalidate()
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPosition()
            }
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
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
        guard let snapshot = SettingsWindowLocator.frontmostWindow() else {
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
}
