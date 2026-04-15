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
