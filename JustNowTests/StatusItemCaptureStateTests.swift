import XCTest
@testable import JustNow

final class StatusItemCaptureStateTests: XCTestCase {
    func testRecordingStatusesResolveToRecording() {
        for status in ["Active", "Starting...", "Resuming...", "Restarting..."] {
            XCTAssertEqual(
                StatusItemCaptureState.resolve(
                    statusText: status,
                    isUserPaused: false,
                    blockedStatus: nil
                ),
                .recording,
                "Status \"\(status)\" should keep the recording glyph"
            )
        }
    }

    func testPermissionStatusesKeepRecordingGlyph() {
        // Permission problems surface through their own alert and help item,
        // not the pause glyph.
        for status in ["Awaiting Permission", "No Permission", "Restart Required"] {
            XCTAssertEqual(
                StatusItemCaptureState.resolve(
                    statusText: status,
                    isUserPaused: false,
                    blockedStatus: nil
                ),
                .recording
            )
        }
    }

    func testSystemParkedStatusTextsResolveToSystemPause() {
        let statuses = StatusItemCaptureState.systemPausedStatusTexts
        XCTAssertEqual(
            statuses,
            [
                "Sleeping...", "Screen Off", "Recovering…", "Recovering",
                "Error", "Failed", "Stopped", "Capture Help Needed",
            ]
        )
        for status in statuses {
            XCTAssertEqual(
                StatusItemCaptureState.resolve(
                    statusText: status,
                    isUserPaused: false,
                    blockedStatus: nil
                ),
                .pausedForSystemReason,
                "Status \"\(status)\" should show the system-pause glyph"
            )
        }
    }

    func testLifecycleBlockedStatusesResolveToSystemPause() {
        for blocked in ["Paused (Overlay)", "Session Inactive", "Screen Locked"] {
            XCTAssertEqual(
                StatusItemCaptureState.resolve(
                    statusText: "Active",
                    isUserPaused: false,
                    blockedStatus: blocked
                ),
                .pausedForSystemReason
            )
        }
    }

    func testManualPauseWinsOverSystemReasons() {
        XCTAssertEqual(
            StatusItemCaptureState.resolve(
                statusText: "Recovering…",
                isUserPaused: true,
                blockedStatus: "Screen Locked"
            ),
            .pausedManually
        )
    }

    func testUserBlockedStatusAloneDoesNotImplyManualWithoutFlag() {
        // The funnel passes isUserPaused separately; a "Paused (User)" string
        // reaching the resolver without the flag must not silently read as
        // manual — it falls through to the recording glyph only when nothing
        // else indicates a pause.
        XCTAssertEqual(
            StatusItemCaptureState.resolve(
                statusText: "Paused (User)",
                isUserPaused: false,
                blockedStatus: nil
            ),
            .recording
        )
    }
}
