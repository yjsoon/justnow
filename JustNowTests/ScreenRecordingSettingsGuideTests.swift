import XCTest
@testable import JustNow

final class ScreenRecordingSettingsGuideTests: XCTestCase {
    func testWindowBoundsFlipAgainstPrimaryDisplay() {
        // Quartz y grows downward from the primary display's top edge.
        XCTAssertEqual(
            ScreenRecordingSettingsGuideLayout.appKitFrame(
                fromWindowBounds: CGRect(x: 100, y: 50, width: 600, height: 400),
                primaryScreenHeight: 900
            ),
            CGRect(x: 100, y: 450, width: 600, height: 400)
        )
        // A window on a display stacked above the primary has negative Quartz y.
        XCTAssertEqual(
            ScreenRecordingSettingsGuideLayout.appKitFrame(
                fromWindowBounds: CGRect(x: -300, y: -700, width: 500, height: 300),
                primaryScreenHeight: 900
            ),
            CGRect(x: -300, y: 1300, width: 500, height: 300)
        )
    }

    func testGuideSitsOverContentPaneNearBottomEdge() {
        let frame = ScreenRecordingSettingsGuideLayout.guideFrame(
            size: CGSize(width: 440, height: 110),
            settingsWindow: CGRect(x: 100, y: 450, width: 600, height: 400),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)
        )
        // Content pane spans x 300...700, so a 440-wide guide centres at x 280.
        XCTAssertEqual(frame, CGRect(x: 280, y: 466, width: 440, height: 110))
    }

    func testNarrowSettingsWindowUsesAThirdForTheSidebar() {
        let frame = ScreenRecordingSettingsGuideLayout.guideFrame(
            size: CGSize(width: 440, height: 110),
            settingsWindow: CGRect(x: 100, y: 450, width: 300, height: 400),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)
        )
        // Sidebar is 100 wide (not 200), so content spans x 200...400 and the
        // wider guide centres on it at x 80.
        XCTAssertEqual(frame, CGRect(x: 80, y: 466, width: 440, height: 110))
    }

    func testGuideStaysOnScreenWhenSettingsHangsOffTheEdge() {
        let frame = ScreenRecordingSettingsGuideLayout.guideFrame(
            size: CGSize(width: 440, height: 110),
            settingsWindow: CGRect(x: 1200, y: -100, width: 600, height: 400),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)
        )
        XCTAssertEqual(frame, CGRect(x: 992, y: 8, width: 440, height: 110))
    }
}
