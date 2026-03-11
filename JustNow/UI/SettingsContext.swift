//
//  SettingsContext.swift
//  JustNow
//

import Observation
import Sparkle

@MainActor
@Observable
final class SettingsContext {
    var frameBuffer: FrameBuffer?
    var launchAtLoginManager: LaunchAtLoginManager?
    var updater: SPUUpdater?
    private let onCheckForUpdates: @MainActor () -> Void
    private let onShortcutChanged: @MainActor () -> Void

    init(
        frameBuffer: FrameBuffer? = nil,
        launchAtLoginManager: LaunchAtLoginManager? = nil,
        updater: SPUUpdater? = nil,
        onCheckForUpdates: @escaping @MainActor () -> Void = {},
        onShortcutChanged: @escaping @MainActor () -> Void = {}
    ) {
        self.frameBuffer = frameBuffer
        self.launchAtLoginManager = launchAtLoginManager
        self.updater = updater
        self.onCheckForUpdates = onCheckForUpdates
        self.onShortcutChanged = onShortcutChanged
    }

    func checkForUpdates() {
        onCheckForUpdates()
    }

    func notifyShortcutChanged() {
        onShortcutChanged()
    }

    var canConfigureLaunchAtLogin: Bool {
        launchAtLoginManager?.canConfigure ?? false
    }

    func launchAtLoginEnabled() -> Bool {
        launchAtLoginManager?.isEnabled ?? false
    }

    func setLaunchAtLoginEnabled(_ isEnabled: Bool) throws -> LaunchAtLoginManager.ChangeResult {
        guard let launchAtLoginManager else {
            throw LaunchAtLoginError.serviceUnavailable
        }

        return try launchAtLoginManager.setEnabled(isEnabled)
    }
}
