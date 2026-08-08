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
    nonisolated static let timelineScrollDirection = "timelineScrollDirection"
    nonisolated static let showMenuBarIcon = "showMenuBarIcon"
    nonisolated static let hasSeenMenuBarHideInfo = "hasSeenMenuBarHideInfo"
    nonisolated static let screenshotSaveLocationOverride = "screenshotSaveLocationOverride"
    nonisolated static let screenshotSaveToFolder = "screenshotSaveToFolder"
    nonisolated static let screenshotSaveToClipboard = "screenshotSaveToClipboard"
    nonisolated static let hasSeenSaveQualityInfo = "hasSeenSaveQualityInfo"
    nonisolated static let regionScreenshotShortcutHintCount = "regionScreenshotShortcutHintCount"
    nonisolated static let settingsMigrationVersion = "settingsMigrationVersion"
    /// Launch-scoped beta. This is the sole enable flag for hybrid RAM history.
    nonisolated static let reducedDiskWritesEnabled = "reducedDiskWritesEnabled"
    nonisolated static let recentDetailMemoryMiB = "recentDetailMemoryMiB"
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

enum TimelineScrollDirection: String, CaseIterable, Identifiable {
    case off
    case upToRewind
    case downToRewind

    nonisolated var id: String { rawValue }

    nonisolated var settingsLabel: String {
        switch self {
        case .off:
            "Off"
        case .upToRewind:
            "Scroll up to rewind"
        case .downToRewind:
            "Scroll down to rewind"
        }
    }

    /// Returns the signed delta expected by `OverlayViewModel.scrollBy`.
    /// Positive values rewind; negative values move forwards.
    nonisolated func navigationDelta(
        horizontalDelta: CGFloat,
        verticalDelta: CGFloat
    ) -> CGFloat? {
        guard self != .off else { return nil }

        let dominantDelta = abs(horizontalDelta) > abs(verticalDelta)
            ? horizontalDelta
            : verticalDelta
        guard dominantDelta != 0 else { return nil }

        return self == .upToRewind ? dominantDelta : -dominantDelta
    }

    nonisolated static func storedValue(_ rawValue: String) -> TimelineScrollDirection {
        TimelineScrollDirection(rawValue: rawValue) ?? .upToRewind
    }
}

nonisolated struct TimelineScrollAccumulator {
    /// Precise devices report points and emit many events per gesture. Four
    /// points keeps a gentle gesture responsive without turning every tiny
    /// update into a full timeline-entry jump.
    static let preciseStepThreshold: CGFloat = 4

    private(set) var accumulatedDelta: CGFloat = 0

    mutating func navigationStep(
        for delta: CGFloat,
        hasPreciseScrollingDeltas: Bool,
        isMomentum: Bool = false
    ) -> CGFloat? {
        guard delta.isFinite, delta != 0 else { return nil }

        // Momentum can continue long after the user's fingers leave the
        // device. Timeline navigation should stop with the direct gesture.
        guard !isMomentum else {
            reset()
            return nil
        }

        // A traditional mouse-wheel tick is already a discrete action, even
        // when a driver reports a fractional value.
        guard hasPreciseScrollingDeltas else {
            reset()
            return delta > 0 ? 1 : -1
        }

        if accumulatedDelta != 0,
           (accumulatedDelta > 0) != (delta > 0) {
            accumulatedDelta = 0
        }
        accumulatedDelta += delta

        guard abs(accumulatedDelta) >= Self.preciseStepThreshold else {
            return nil
        }

        let step: CGFloat = accumulatedDelta > 0 ? 1 : -1
        accumulatedDelta -= step * Self.preciseStepThreshold
        return step
    }

    mutating func reset() {
        accumulatedDelta = 0
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
    nonisolated static let timelineScrollDirection = TimelineScrollDirection.upToRewind.rawValue
    nonisolated static let showMenuBarIcon = true
    nonisolated static let hasSeenMenuBarHideInfo = false
    nonisolated static let screenshotSaveLocationOverride = ""
    nonisolated static let screenshotSaveToFolder = true
    nonisolated static let screenshotSaveToClipboard = false
    nonisolated static let hasSeenSaveQualityInfo = false
    nonisolated static let reducedDiskWritesEnabled = true
    nonisolated static let recentDetailMemoryMiB = RecentDetailMemoryLimit.defaultValue.rawValue
}

nonisolated enum RecentDetailMemoryLimit: Int, CaseIterable, Identifiable, Sendable {
    case mb256 = 256
    case mb512 = 512
    case mb1024 = 1024

    static let defaultValue: Self = .mb512

    var id: Int { rawValue }
    var byteCount: Int { rawValue * 1024 * 1024 }

    var label: String {
        switch self {
        case .mb256: "256 MB"
        case .mb512: "512 MB"
        case .mb1024: "1 GB"
        }
    }

    static func resolved(from rawValue: Int) -> Self {
        Self(rawValue: rawValue) ?? .defaultValue
    }
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
