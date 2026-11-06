enum ScreenRecordingPermissionLaunchState {
    case granted
    case requestedThisLaunch
    case deniedPreviously
}

enum ScreenRecordingPermissionPromptResolution {
    case none
    case showPermissionAlert
    case showRestartAlert
}

struct ScreenRecordingPermissionState {
    private(set) var didRequestPermissionThisLaunch = false
    private(set) var didShowPermissionAlertThisLaunch = false
    private(set) var didShowPermissionRestartAlertThisLaunch = false
    private(set) var isAwaitingPromptResolution = false
    private(set) var didDeactivateForPromptThisLaunch = false
    /// The user has left JustNow for permission setup this launch. A grant made
    /// then is invisible to this process (preflight stays false until relaunch),
    /// so the permission alert offers Relaunch JustNow from here on.
    private(set) var mayHaveGrantedThisLaunch = false

    mutating func resolveLaunchState(
        hasPermission: Bool,
        requestPermission: () -> Bool
    ) -> ScreenRecordingPermissionLaunchState {
        if hasPermission {
            return .granted
        }

        guard !didRequestPermissionThisLaunch else {
            return .deniedPreviously
        }

        didRequestPermissionThisLaunch = true
        if requestPermission() {
            return .granted
        }

        isAwaitingPromptResolution = true
        didDeactivateForPromptThisLaunch = false
        return .requestedThisLaunch
    }

    mutating func noteApplicationDidResignActive() {
        guard isAwaitingPromptResolution else { return }
        didDeactivateForPromptThisLaunch = true
        mayHaveGrantedThisLaunch = true
    }

    mutating func resolvePendingPrompt(hasPermission: Bool) -> ScreenRecordingPermissionPromptResolution {
        guard isAwaitingPromptResolution else { return .none }

        if hasPermission {
            isAwaitingPromptResolution = false
            return .showRestartAlert
        }

        guard didDeactivateForPromptThisLaunch else {
            return .none
        }

        isAwaitingPromptResolution = false
        return .showPermissionAlert
    }

    /// The user chose Open System Settings without permission: show the alert
    /// again when they return, since a grant there may not reach this process.
    mutating func noteOpenedPermissionSettings() {
        isAwaitingPromptResolution = true
        didDeactivateForPromptThisLaunch = false
    }

    mutating func consumePermissionAlertPresentation(force: Bool = false) -> Bool {
        guard force || !didShowPermissionAlertThisLaunch else { return false }
        didShowPermissionAlertThisLaunch = true
        return true
    }

    mutating func consumeRestartAlertPresentation() -> Bool {
        guard !didShowPermissionRestartAlertThisLaunch else { return false }
        didShowPermissionRestartAlertThisLaunch = true
        return true
    }
}
