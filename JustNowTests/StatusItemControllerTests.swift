import AppKit
import XCTest
@testable import JustNow

@MainActor
final class StatusItemControllerTests: XCTestCase {
    private var controllers: [StatusItemController] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    override func tearDown() {
        controllers.removeAll()
        super.tearDown()
    }

    func testSetPausedUpdatesPauseMenuItemTitle() throws {
        let controller = makeController()

        controller.setPaused(true)

        XCTAssertEqual(
            try XCTUnwrap(controller.item(for: .pauseToggle)).title,
            "Resume Recording"
        )

        controller.setPaused(false)

        XCTAssertEqual(
            try XCTUnwrap(controller.item(for: .pauseToggle)).title,
            "Pause Recording"
        )
    }

    func testSetFrameCountCaptureStatusAndPermissionHelpUpdateMenuItems() throws {
        let controller = makeController()

        controller.setFrameCount(42)
        controller.setCaptureStatus("Active")
        controller.setPermissionHelpVisible(true)

        XCTAssertEqual(
            try XCTUnwrap(controller.item(for: .frameCount)).title,
            "Frames: 42"
        )
        XCTAssertEqual(
            try XCTUnwrap(controller.item(for: .captureStatus)).title,
            "Capture: Active"
        )
        XCTAssertFalse(try XCTUnwrap(controller.item(for: .permissionHelp)).isHidden)
    }

    func testMenuWillOpenInvokesRefreshCallback() {
        var callbackCount = 0
        let controller = makeController(menuWillOpen: {
            callbackCount += 1
        })

        controller.menuWillOpen(NSMenu())

        XCTAssertEqual(callbackCount, 1)
    }

    func testSetCaptureStateDrivesButtonGlyph() {
        let controller = makeController()

        controller.setCaptureState(.recording)
        XCTAssertEqual(controller.statusItemButtonDescriptionForTesting, "JustNow")

        controller.setCaptureState(.pausedManually)
        XCTAssertEqual(controller.statusItemButtonDescriptionForTesting, "JustNow (Paused)")

        controller.setCaptureState(.pausedForSystemReason)
        XCTAssertEqual(controller.statusItemButtonDescriptionForTesting, "JustNow (Not Recording)")
    }

    func testSetPausedOnlyUpdatesMenuRowNotButtonGlyph() {
        let controller = makeController()

        controller.setCaptureState(.recording)
        controller.setPaused(true)

        XCTAssertEqual(controller.statusItemButtonDescriptionForTesting, "JustNow")
        XCTAssertEqual(
            controller.item(for: .pauseToggle)?.title,
            "Resume Recording"
        )
    }

    private func makeController(menuWillOpen: @escaping () -> Void = {}) -> StatusItemController {
        let controller = StatusItemController(
            actions: StatusItemControllerActions(
                showTimeline: {},
                toggleCapturePause: {},
                showSettings: {},
                checkForUpdates: {},
                quitApp: {},
                showScreenRecordingHelp: {},
                menuWillOpen: menuWillOpen
            )
        )
        controllers.append(controller)
        return controller
    }
}
