import XCTest
@testable import JustNow

final class RewindDragActionTests: XCTestCase {
    func testSaveTextDefaultUsesCommandForScreenshot() {
        XCTAssertFalse(RewindDragAction.saveText.performsScreenshot(commandHeld: false))
        XCTAssertTrue(RewindDragAction.saveText.performsScreenshot(commandHeld: true))
    }

    func testSaveScreenshotDefaultInvertsCommandGesture() {
        XCTAssertTrue(RewindDragAction.saveScreenshot.performsScreenshot(commandHeld: false))
        XCTAssertFalse(RewindDragAction.saveScreenshot.performsScreenshot(commandHeld: true))
    }

    func testArmedRegionScreenshotAlwaysCapturesScreenshot() {
        XCTAssertTrue(RewindDragAction.saveText.performsScreenshot(commandHeld: false, isArmed: true))
        XCTAssertTrue(RewindDragAction.saveScreenshot.performsScreenshot(commandHeld: true, isArmed: true))
    }

    func testStoredValueFallsBackToSaveText() {
        XCTAssertEqual(RewindDragAction.storedValue("missing"), .saveText)
    }
}
