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
    var launchAtLoginManager: LaunchAtLoginManager? {
        didSet { refreshLaunchAtLoginState() }
    }
    private(set) var launchAtLoginEnabled = false
    var updater: SPUUpdater? {
        didSet { observeUpdater() }
    }
    private(set) var automaticallyChecksForUpdates = false
    private(set) var automaticallyDownloadsUpdates = false
    private(set) var allowsAutomaticUpdates = false
    private(set) var canCheckForUpdates = false
    @ObservationIgnored private var updaterObservations: [NSKeyValueObservation] = []
    private let onCheckForUpdates: @MainActor () -> Void
    private let onShortcutChanged: @MainActor () -> Void
    private let onRelaunch: @MainActor () -> Void

    init(
        frameBuffer: FrameBuffer? = nil,
        launchAtLoginManager: LaunchAtLoginManager? = nil,
        updater: SPUUpdater? = nil,
        onCheckForUpdates: @escaping @MainActor () -> Void = {},
        onShortcutChanged: @escaping @MainActor () -> Void = {},
        onRelaunch: @escaping @MainActor () -> Void = {}
    ) {
        self.frameBuffer = frameBuffer
        self.launchAtLoginManager = launchAtLoginManager
        self.updater = updater
        self.onCheckForUpdates = onCheckForUpdates
        self.onShortcutChanged = onShortcutChanged
        self.onRelaunch = onRelaunch
        observeUpdater()
        refreshLaunchAtLoginState()
    }

    private func observeUpdater() {
        updaterObservations.removeAll()
        syncUpdaterState()
        guard let updater else { return }
        // Sparkle can change these outside Settings, including in its own
        // permission dialog. Keep both Settings hosts on the same snapshot.
        updaterObservations = [
            \.automaticallyChecksForUpdates,
            \.automaticallyDownloadsUpdates,
            \.allowsAutomaticUpdates,
            \.canCheckForUpdates
        ].map { (keyPath: KeyPath<SPUUpdater, Bool>) in
            updater.observe(keyPath, options: [.new]) { [weak self] observedUpdater, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.updater === observedUpdater else { return }
                    self.syncUpdaterState()
                }
            }
        }
    }

    private func syncUpdaterState() {
        automaticallyChecksForUpdates = updater?.automaticallyChecksForUpdates ?? false
        automaticallyDownloadsUpdates = updater?.automaticallyDownloadsUpdates ?? false
        allowsAutomaticUpdates = updater?.allowsAutomaticUpdates ?? false
        canCheckForUpdates = updater?.canCheckForUpdates ?? false
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updater?.automaticallyChecksForUpdates = enabled
        syncUpdaterState()
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        updater?.automaticallyDownloadsUpdates = enabled
        syncUpdaterState()
    }

    func checkForUpdates() {
        onCheckForUpdates()
    }

    func notifyShortcutChanged() {
        onShortcutChanged()
    }

    func relaunch() {
        onRelaunch()
    }

    var canConfigureLaunchAtLogin: Bool {
        launchAtLoginManager?.canConfigure ?? false
    }

    func refreshLaunchAtLoginState() {
        launchAtLoginEnabled = launchAtLoginManager?.isEnabled ?? false
    }

    func setLaunchAtLoginEnabled(_ isEnabled: Bool) throws -> LaunchAtLoginManager.ChangeResult {
        guard let launchAtLoginManager else {
            throw LaunchAtLoginError.serviceUnavailable
        }

        defer { refreshLaunchAtLoginState() }
        return try launchAtLoginManager.setEnabled(isEnabled)
    }
}
