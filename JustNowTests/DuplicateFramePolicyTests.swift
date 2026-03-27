import XCTest
@testable import JustNow

final class DuplicateFramePolicyTests: XCTestCase {

    // MARK: - exact(atMostEvery:) clamping

    func testExactClampsIntervalBelowHalfSecond() {
        let policy = DuplicateFramePolicy.exact(atMostEvery: 0.1)
        XCTAssertEqual(policy.minimumSpacing, 0.5, "Intervals below 0.5 should be clamped to 0.5")
        XCTAssertEqual(policy.hashThreshold, 0)
    }

    func testExactClampsZeroInterval() {
        let policy = DuplicateFramePolicy.exact(atMostEvery: 0)
        XCTAssertEqual(policy.minimumSpacing, 0.5)
    }

    func testExactClampsNegativeInterval() {
        let policy = DuplicateFramePolicy.exact(atMostEvery: -5)
        XCTAssertEqual(policy.minimumSpacing, 0.5)
    }

    func testExactPreservesIntervalAboveHalfSecond() {
        let policy = DuplicateFramePolicy.exact(atMostEvery: 2.0)
        XCTAssertEqual(policy.minimumSpacing, 2.0)
        XCTAssertEqual(policy.hashThreshold, 0)
    }

    func testExactPreservesHalfSecondExactly() {
        let policy = DuplicateFramePolicy.exact(atMostEvery: 0.5)
        XCTAssertEqual(policy.minimumSpacing, 0.5)
    }

    // MARK: - Presets

    func testStandardPreset() {
        let policy = DuplicateFramePolicy.standard
        XCTAssertEqual(policy.hashThreshold, 0, "Standard uses exact matching")
        XCTAssertEqual(policy.minimumSpacing, 0.5)
    }

    func testLowPowerPreset() {
        let policy = DuplicateFramePolicy.lowPower
        XCTAssertEqual(policy.hashThreshold, 1, "Low power allows 1-bit hash difference")
        XCTAssertEqual(policy.minimumSpacing, 5, "Low power spaces captures 5s apart")
    }

    // MARK: - Equatable

    func testEqualPoliciesAreEqual() {
        let a = DuplicateFramePolicy.exact(atMostEvery: 1.0)
        let b = DuplicateFramePolicy.exact(atMostEvery: 1.0)
        XCTAssertEqual(a, b)
    }

    func testDifferentPoliciesAreNotEqual() {
        XCTAssertNotEqual(DuplicateFramePolicy.standard, DuplicateFramePolicy.lowPower)
    }
}
