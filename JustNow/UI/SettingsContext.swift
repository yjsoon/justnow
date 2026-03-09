//
//  SettingsContext.swift
//  JustNow
//

import Observation

@MainActor
@Observable
final class SettingsContext {
    var frameBuffer: FrameBuffer?
    private let onShortcutChanged: @MainActor () -> Void

    init(
        frameBuffer: FrameBuffer? = nil,
        onShortcutChanged: @escaping @MainActor () -> Void = {}
    ) {
        self.frameBuffer = frameBuffer
        self.onShortcutChanged = onShortcutChanged
    }

    func notifyShortcutChanged() {
        onShortcutChanged()
    }
}
