import CoreGraphics
import XCTest
@testable import JustNow

final class OverlayWindowLayoutTests: XCTestCase {
    func testContentFrameUsesWindowLocalOriginForSecondaryDisplayToTheRight() {
        let screenFrame = CGRect(x: 1728, y: 0, width: 2560, height: 1440)

        let contentFrame = OverlayWindowLayout.contentFrame(forScreenFrame: screenFrame)

        XCTAssertEqual(contentFrame.origin, .zero)
        XCTAssertEqual(contentFrame.size, screenFrame.size)
    }

    func testContentFrameUsesWindowLocalOriginForSecondaryDisplayAbove() {
        let screenFrame = CGRect(x: -160, y: 1117, width: 3008, height: 1692)

        let contentFrame = OverlayWindowLayout.contentFrame(forScreenFrame: screenFrame)

        XCTAssertEqual(contentFrame.origin, .zero)
        XCTAssertEqual(contentFrame.size, screenFrame.size)
    }
}
