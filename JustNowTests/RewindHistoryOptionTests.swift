import Foundation
import XCTest
@testable import JustNow

final class RewindHistoryOptionTests: XCTestCase {
    func testResolvedFallsBackToDefaultForUnknownRawValues() {
        XCTAssertEqual(RewindHistoryOption.resolved(from: 0), .defaultValue)
        XCTAssertEqual(RewindHistoryOption.resolved(from: -1), .defaultValue)
        XCTAssertEqual(RewindHistoryOption.resolved(from: 12_345), .defaultValue)
        XCTAssertEqual(RewindHistoryOption.resolved(from: 1_800), .thirtyMinutes)
    }

    func testRetainedDurationFloorsAtOneHourForSearchScope() {
        XCTAssertEqual(RewindHistoryOption.thirtyMinutes.retainedDuration, 60 * 60)
        XCTAssertEqual(RewindHistoryOption.twoHours.retainedDuration, 2 * 60 * 60)
        XCTAssertEqual(RewindHistoryOption.twentyFourHours.retainedDuration, 24 * 60 * 60)
    }

    /// RetentionManager assigns each frame to the first tier whose maxAge
    /// covers it, so tiers must be strictly ascending with positive spacing,
    /// and the deepest tier must reach the full retained duration — otherwise
    /// retained frames would be silently pruned as "beyond all tiers".
    func testEveryOptionProducesWellFormedRetentionTiers() throws {
        for option in RewindHistoryOption.allCases {
            let tiers = option.retentionPolicy.tiers
            XCTAssertFalse(tiers.isEmpty, "\(option) has no tiers")

            for (previous, next) in zip(tiers, tiers.dropFirst()) {
                XCTAssertLessThan(
                    previous.maxAge,
                    next.maxAge,
                    "\(option) tiers must be strictly ascending"
                )
            }
            for tier in tiers {
                XCTAssertGreaterThan(tier.minimumSpacing, 0, "\(option) has non-positive spacing")
            }

            let deepest = try XCTUnwrap(tiers.last)
            XCTAssertEqual(
                deepest.maxAge,
                option.retainedDuration,
                "\(option) deepest tier must cover the retained duration"
            )
        }
    }
}
