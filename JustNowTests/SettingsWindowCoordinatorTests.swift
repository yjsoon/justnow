import AppKit
import XCTest
@testable import JustNow

@MainActor
final class SettingsWindowCoordinatorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testShowCloseShowReusesSameWindow() throws {
        let coordinator = SettingsWindowCoordinator(
            makeContentView: { NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)) },
            activateApp: {}
        )

        coordinator.show()

        let firstWindow = try XCTUnwrap(coordinator.window)
        XCTAssertTrue(firstWindow.isVisible)

        firstWindow.performClose(nil)

        XCTAssertFalse(firstWindow.isVisible)
        XCTAssertTrue(firstWindow === coordinator.window)

        coordinator.show()

        XCTAssertTrue(firstWindow === coordinator.window)
        XCTAssertTrue(firstWindow.isVisible)
    }
}
