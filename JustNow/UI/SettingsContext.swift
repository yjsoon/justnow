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
    var updater: SPUUpdater?
    private let onCheckForUpdates: @MainActor () -> Void
    private let onShortcutChanged: @MainActor () -> Void

    init(
        frameBuffer: FrameBuffer? = nil,
        updater: SPUUpdater? = nil,
        onCheckForUpdates: @escaping @MainActor () -> Void = {},
        onShortcutChanged: @escaping @MainActor () -> Void = {}
    ) {
        self.frameBuffer = frameBuffer
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
}
