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

    func testSmallNonZeroDeltasRemainAvailableForAccumulation() {
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

    func testPreciseDeltasAccumulateBeforeNavigating() {
        var accumulator = TimelineScrollAccumulator()

        XCTAssertNil(accumulator.navigationStep(for: 1, hasPreciseScrollingDeltas: true))
        XCTAssertNil(accumulator.navigationStep(for: 1, hasPreciseScrollingDeltas: true))
        XCTAssertNil(accumulator.navigationStep(for: 1, hasPreciseScrollingDeltas: true))
        XCTAssertEqual(
            accumulator.navigationStep(for: 1, hasPreciseScrollingDeltas: true),
            1
        )
    }

    func testTraditionalWheelTickNavigatesImmediately() {
        var accumulator = TimelineScrollAccumulator()

        XCTAssertEqual(
            accumulator.navigationStep(for: -0.25, hasPreciseScrollingDeltas: false),
            -1
        )
    }

    func testPreciseDirectionReversalDiscardsOppositeRemainder() {
        var accumulator = TimelineScrollAccumulator()

        XCTAssertNil(accumulator.navigationStep(for: 3, hasPreciseScrollingDeltas: true))
        XCTAssertNil(accumulator.navigationStep(for: -1, hasPreciseScrollingDeltas: true))
        XCTAssertEqual(
            accumulator.navigationStep(for: -3, hasPreciseScrollingDeltas: true),
            -1
        )
    }

    func testMomentumAndResetDiscardAccumulatedMovement() {
        var accumulator = TimelineScrollAccumulator()

        XCTAssertNil(accumulator.navigationStep(for: 3, hasPreciseScrollingDeltas: true))
        XCTAssertNil(accumulator.navigationStep(
            for: 2,
            hasPreciseScrollingDeltas: true,
            isMomentum: true
        ))
        XCTAssertEqual(accumulator.accumulatedDelta, 0)

        XCTAssertNil(accumulator.navigationStep(for: 3, hasPreciseScrollingDeltas: true))
        accumulator.reset()
        XCTAssertNil(accumulator.navigationStep(for: 1, hasPreciseScrollingDeltas: true))
    }
}
