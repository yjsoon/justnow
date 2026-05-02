import Foundation

enum AppStorageKey {
    static let captureInterval = "captureInterval"
    static let rewindHistorySeconds = "rewindHistorySeconds"
    static let recentTimelineWindowSeconds = "recentTimelineWindowSeconds"
    static let reduceCaptureOnBattery = "reduceCaptureOnBattery"
    static let shortcutKeyCode = "shortcutKeyCode"
    static let shortcutModifiers = "shortcutModifiers"
    static let capturePauseShortcutKeyCode = "capturePauseShortcutKeyCode"
    static let capturePauseShortcutModifiers = "capturePauseShortcutModifiers"
    static let overlayDismissKeyCode = "overlayDismissKeyCode"
    static let overlayDismissModifiers = "overlayDismissModifiers"
    static let textGrabSoundEnabled = "textGrabSoundEnabled"
    static let saveScreenshotSoundEnabled = "saveScreenshotSoundEnabled"
    static let textGrabDebugPreviewEnabled = "textGrabDebugPreviewEnabled"
    static let showMenuBarIcon = "showMenuBarIcon"
    static let hasSeenMenuBarHideInfo = "hasSeenMenuBarHideInfo"
    static let screenshotSaveLocationOverride = "screenshotSaveLocationOverride"
    static let screenshotSaveToFolder = "screenshotSaveToFolder"
    static let screenshotSaveToClipboard = "screenshotSaveToClipboard"
    static let hasSeenSaveQualityInfo = "hasSeenSaveQualityInfo"
    static let regionScreenshotShortcutHintCount = "regionScreenshotShortcutHintCount"
}

enum AppStorageDefault {
    static let captureInterval = 0.5
    static let rewindHistorySeconds = RewindHistoryOption.defaultValue.rawValue
    static let recentTimelineWindowSeconds = RecentTimelineWindow.defaultValue.rawValue
    static let reduceCaptureOnBattery = true
    static let shortcutKeyCode = 38  // J key
    static let shortcutModifiers = 1_572_864  // ⌘⌥
    static let capturePauseShortcutKeyCode = 38  // J key
    static let capturePauseShortcutModifiers = 1_703_936  // ⌘⌥⇧
    static let overlayDismissKeyCode = 53
    static let overlayDismissModifiers = 0
    static let textGrabSoundEnabled = true
    static let saveScreenshotSoundEnabled = true
    static let textGrabDebugPreviewEnabled = false
    static let showMenuBarIcon = true
    static let hasSeenMenuBarHideInfo = false
    static let screenshotSaveLocationOverride = ""
    static let screenshotSaveToFolder = true
    static let screenshotSaveToClipboard = false
    static let hasSeenSaveQualityInfo = false
}
