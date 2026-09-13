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

    func testRecordingStatusTextsIsExactlyTheAllowlist() {
        XCTAssertEqual(
            StatusItemCaptureState.recordingStatusTexts,
            [
                "Active",
                "Starting...",
                "Resuming...",
                "Restarting...",
                "Awaiting Permission",
                "No Permission",
                "Restart Required",
            ]
        )
    }

    func testSystemParkedStatusTextsResolveToSystemPause() {
        for status in ["Sleeping...", "Screen Off", "Recovering…", "Error", "Failed", "Stopped", "Capture Help Needed"] {
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

    func testLifecycleStatusTextsWithoutFlagResolveToSystemPause() {
        // Launch-while-locked and the unlock-retry path publish "Screen Locked"
        // without setting the lifecycle lock flag; "Session Inactive" and
        // "Paused (Overlay)" are similarly plain status text, not the blocked
        // flag. All three must still fail safe to the system-pause glyph.
        for status in ["Screen Locked", "Session Inactive", "Paused (Overlay)"] {
            XCTAssertEqual(
                StatusItemCaptureState.resolve(
                    statusText: status,
                    isUserPaused: false,
                    blockedStatus: nil
                ),
                .pausedForSystemReason
            )
        }
    }

    func testUnknownStatusFailsSafeToSystemPause() {
        XCTAssertEqual(
            StatusItemCaptureState.resolve(
                statusText: "Some Future Status",
                isUserPaused: false,
                blockedStatus: nil
            ),
            .pausedForSystemReason
        )
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

    func testUserPausedTextWithoutFlagIsNotManual() {
        // The funnel passes isUserPaused separately; a "Paused (User)" string
        // reaching the resolver without the flag must not silently read as
        // manual — it is a pause, just not one the toggle row should claim.
        XCTAssertEqual(
            StatusItemCaptureState.resolve(
                statusText: "Paused (User)",
                isUserPaused: false,
                blockedStatus: nil
            ),
            .pausedForSystemReason
        )
    }
}
