import Foundation

/// Menu bar icon state derived from the capture status funnel. Manual pause
/// wins over everything; a lifecycle block or any status outside the
/// recording allowlist flips the glyph so a silently non-recording app is
/// visible at a glance.
enum StatusItemCaptureState: Equatable {
    case recording
    case pausedManually
    case pausedForSystemReason

    /// Status-line texts that keep the recording glyph. Transitional states are
    /// about to record; permission states surface through their own alert and
    /// help menu item. Every other status means capture is parked, so an
    /// unlisted status fails safe to the system-pause glyph.
    static let recordingStatusTexts: Set<String> = [
        "Active",
        "Starting...",
        "Resuming...",
        "Restarting...",
        "Awaiting Permission",
        "No Permission",
        "Restart Required",
    ]

    static func resolve(
        statusText: String,
        isUserPaused: Bool,
        blockedStatus: String?
    ) -> StatusItemCaptureState {
        if isUserPaused {
            return .pausedManually
        }
        // A non-nil blocked status here is a system reason: user pause is
        // handled above, so the remainder are overlay/session/lock.
        if blockedStatus != nil {
            return .pausedForSystemReason
        }
        if recordingStatusTexts.contains(statusText) {
            return .recording
        }
        return .pausedForSystemReason
    }
}
