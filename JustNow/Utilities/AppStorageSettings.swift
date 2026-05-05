import Foundation

enum AppStorageKey {
    nonisolated static let captureInterval = "captureInterval"
    nonisolated static let rewindHistorySeconds = "rewindHistorySeconds"
    nonisolated static let recentTimelineWindowSeconds = "recentTimelineWindowSeconds"
    nonisolated static let reduceCaptureOnBattery = "reduceCaptureOnBattery"
    nonisolated static let shortcutKeyCode = "shortcutKeyCode"
    nonisolated static let shortcutModifiers = "shortcutModifiers"
    nonisolated static let capturePauseShortcutKeyCode = "capturePauseShortcutKeyCode"
    nonisolated static let capturePauseShortcutModifiers = "capturePauseShortcutModifiers"
    nonisolated static let overlayDismissKeyCode = "overlayDismissKeyCode"
    nonisolated static let overlayDismissModifiers = "overlayDismissModifiers"
    nonisolated static let textGrabSoundEnabled = "textGrabSoundEnabled"
    nonisolated static let saveScreenshotSoundEnabled = "saveScreenshotSoundEnabled"
    nonisolated static let textGrabDebugPreviewEnabled = "textGrabDebugPreviewEnabled"
    nonisolated static let showMenuBarIcon = "showMenuBarIcon"
    nonisolated static let hasSeenMenuBarHideInfo = "hasSeenMenuBarHideInfo"
    nonisolated static let screenshotSaveLocationOverride = "screenshotSaveLocationOverride"
    nonisolated static let screenshotSaveToFolder = "screenshotSaveToFolder"
    nonisolated static let screenshotSaveToClipboard = "screenshotSaveToClipboard"
    nonisolated static let hasSeenSaveQualityInfo = "hasSeenSaveQualityInfo"
    nonisolated static let regionScreenshotShortcutHintCount = "regionScreenshotShortcutHintCount"
}

enum AppStorageDefault {
    nonisolated static let captureInterval = 0.5
    nonisolated static let rewindHistorySeconds = RewindHistoryOption.defaultValue.rawValue
    nonisolated static let recentTimelineWindowSeconds = RecentTimelineWindow.defaultValue.rawValue
    nonisolated static let reduceCaptureOnBattery = true
    nonisolated static let shortcutKeyCode = 38  // J key
    nonisolated static let shortcutModifiers = 1_572_864  // ⌘⌥
    nonisolated static let capturePauseShortcutKeyCode = 38  // J key
    nonisolated static let capturePauseShortcutModifiers = 1_703_936  // ⌘⌥⇧
    nonisolated static let overlayDismissKeyCode = 53
    nonisolated static let overlayDismissModifiers = 0
    nonisolated static let textGrabSoundEnabled = true
    nonisolated static let saveScreenshotSoundEnabled = true
    nonisolated static let textGrabDebugPreviewEnabled = false
    nonisolated static let showMenuBarIcon = true
    nonisolated static let hasSeenMenuBarHideInfo = false
    nonisolated static let screenshotSaveLocationOverride = ""
    nonisolated static let screenshotSaveToFolder = true
    nonisolated static let screenshotSaveToClipboard = false
    nonisolated static let hasSeenSaveQualityInfo = false
}
