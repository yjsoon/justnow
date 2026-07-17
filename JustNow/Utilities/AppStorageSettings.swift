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
    nonisolated static let rewindDragAction = "rewindDragAction"
    nonisolated static let showMenuBarIcon = "showMenuBarIcon"
    nonisolated static let hasSeenMenuBarHideInfo = "hasSeenMenuBarHideInfo"
    nonisolated static let screenshotSaveLocationOverride = "screenshotSaveLocationOverride"
    nonisolated static let screenshotSaveToFolder = "screenshotSaveToFolder"
    nonisolated static let screenshotSaveToClipboard = "screenshotSaveToClipboard"
    nonisolated static let hasSeenSaveQualityInfo = "hasSeenSaveQualityInfo"
    nonisolated static let regionScreenshotShortcutHintCount = "regionScreenshotShortcutHintCount"
    nonisolated static let settingsMigrationVersion = "settingsMigrationVersion"
}

enum RewindDragAction: String, CaseIterable, Identifiable {
    case saveText
    case saveScreenshot

    nonisolated var id: String { rawValue }

    nonisolated var settingsLabel: String {
        switch self {
        case .saveText:
            "Grab Text"
        case .saveScreenshot:
            "Capture Screenshot"
        }
    }

    nonisolated func performsScreenshot(commandHeld: Bool, isArmed: Bool = false) -> Bool {
        if isArmed {
            return true
        }

        switch self {
        case .saveText:
            return commandHeld
        case .saveScreenshot:
            return !commandHeld
        }
    }

    nonisolated static func storedValue(_ rawValue: String) -> RewindDragAction {
        RewindDragAction(rawValue: rawValue) ?? .saveText
    }
}

enum AppStorageDefault {
    nonisolated static let captureInterval = 0.25
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
    nonisolated static let rewindDragAction = RewindDragAction.saveText.rawValue
    nonisolated static let showMenuBarIcon = true
    nonisolated static let hasSeenMenuBarHideInfo = false
    nonisolated static let screenshotSaveLocationOverride = ""
    nonisolated static let screenshotSaveToFolder = true
    nonisolated static let screenshotSaveToClipboard = false
    nonisolated static let hasSeenSaveQualityInfo = false
}

nonisolated enum CaptureIntervalSetting {
    static let allowedRange = 0.25...5.0

    static func resolved(from value: Double) -> Double {
        guard value.isFinite else { return AppStorageDefault.captureInterval }
        return min(max(value, allowedRange.lowerBound), allowedRange.upperBound)
    }
}

nonisolated enum AppSettingsMigration {
    private static let currentVersion = 1
    private static let legacyCaptureInterval = 0.5
    private static let legacyRecentTimelineWindowSeconds = 300.0

    static func isExistingInstall(
        persistentDomain: [String: Any]?,
        storageDirectoryExists: Bool
    ) -> Bool {
        storageDirectoryExists || persistentDomain?.isEmpty == false
    }

    static func migrateIfNeeded(defaults: UserDefaults, existingInstall: Bool) {
        guard defaults.integer(forKey: AppStorageKey.settingsMigrationVersion) < currentVersion else {
            return
        }

        if existingInstall {
            if defaults.object(forKey: AppStorageKey.captureInterval) == nil {
                defaults.set(legacyCaptureInterval, forKey: AppStorageKey.captureInterval)
            }
            if defaults.object(forKey: AppStorageKey.recentTimelineWindowSeconds) == nil {
                defaults.set(
                    legacyRecentTimelineWindowSeconds,
                    forKey: AppStorageKey.recentTimelineWindowSeconds
                )
            }
        }

        defaults.set(currentVersion, forKey: AppStorageKey.settingsMigrationVersion)
    }
}
