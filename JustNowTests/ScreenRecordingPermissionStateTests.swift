import XCTest
@testable import JustNow

final class ScreenRecordingPermissionStateTests: XCTestCase {
    func testResolveLaunchStateRequestsPermissionOncePerLaunch() {
        var state = ScreenRecordingPermissionState()
        var requestCount = 0

        let first = state.resolveLaunchState(hasPermission: false) {
            requestCount += 1
            return false
        }
        let second = state.resolveLaunchState(hasPermission: false) {
            requestCount += 1
            return false
        }

        XCTAssertEqual(first, .requestedThisLaunch)
        XCTAssertEqual(second, .deniedPreviously)
        XCTAssertEqual(requestCount, 1)
    }

    func testPendingPromptResolutionRequestsRestartWhenPermissionWasGranted() {
        var state = ScreenRecordingPermissionState()

        _ = state.resolveLaunchState(hasPermission: false) { false }

        XCTAssertEqual(
            state.resolvePendingPrompt(hasPermission: true),
            .showRestartAlert
        )
        XCTAssertEqual(
            state.resolvePendingPrompt(hasPermission: true),
            .none
        )
    }

    func testPendingPromptResolutionWaitsForAppDeactivationBeforeShowingPermissionAlert() {
        var state = ScreenRecordingPermissionState()

        _ = state.resolveLaunchState(hasPermission: false) { false }

        XCTAssertEqual(
            state.resolvePendingPrompt(hasPermission: false),
            .none
        )

        state.noteApplicationDidResignActive()

        XCTAssertEqual(
            state.resolvePendingPrompt(hasPermission: false),
            .showPermissionAlert
        )
    }

    func testPermissionAlertPresentationCanBeForced() {
        var state = ScreenRecordingPermissionState()

        XCTAssertTrue(state.consumePermissionAlertPresentation())
        XCTAssertFalse(state.consumePermissionAlertPresentation())
        XCTAssertTrue(state.consumePermissionAlertPresentation(force: true))
    }

    func testRestartAlertPresentationOnlyShowsOnce() {
        var state = ScreenRecordingPermissionState()

        XCTAssertTrue(state.consumeRestartAlertPresentation())
        XCTAssertFalse(state.consumeRestartAlertPresentation())
    }
}
