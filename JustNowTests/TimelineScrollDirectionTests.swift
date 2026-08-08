import XCTest
@testable import JustNow

final class TimelineScrollDirectionTests: XCTestCase {
    func testScrollUpRewindsAndScrollDownMovesForwardsByDefault() {
        XCTAssertEqual(
            TimelineScrollDirection.upToRewind.navigationDelta(
                horizontalDelta: 0,
                verticalDelta: 0.25
            ),
            0.25
        )
        XCTAssertEqual(
            TimelineScrollDirection.upToRewind.navigationDelta(
                horizontalDelta: 0,
                verticalDelta: -0.25
            ),
            -0.25
        )
    }

    func testScrollDownToRewindInvertsNavigation() {
        XCTAssertEqual(
            TimelineScrollDirection.downToRewind.navigationDelta(
                horizontalDelta: 0,
                verticalDelta: 2
            ),
            -2
        )
        XCTAssertEqual(
            TimelineScrollDirection.downToRewind.navigationDelta(
                horizontalDelta: 0,
                verticalDelta: -2
            ),
            2
        )
    }

    func testSmallNonZeroDeltasRemainUsable() {
        XCTAssertEqual(
            TimelineScrollDirection.upToRewind.navigationDelta(
                horizontalDelta: 0,
                verticalDelta: 0.01
            ),
            0.01
        )
    }

    func testHorizontalScrollUsesTheDominantAxis() {
        XCTAssertEqual(
            TimelineScrollDirection.upToRewind.navigationDelta(
                horizontalDelta: 3,
                verticalDelta: 1
            ),
            3
        )
    }

    func testOffAndZeroDeltaDoNotNavigate() {
        XCTAssertNil(
            TimelineScrollDirection.off.navigationDelta(
                horizontalDelta: 2,
                verticalDelta: 0
            )
        )
        XCTAssertNil(
            TimelineScrollDirection.upToRewind.navigationDelta(
                horizontalDelta: 0,
                verticalDelta: 0
            )
        )
    }

    func testUnknownStoredValueFallsBackToScrollUpToRewind() {
        XCTAssertEqual(TimelineScrollDirection.storedValue("missing"), .upToRewind)
    }
}
