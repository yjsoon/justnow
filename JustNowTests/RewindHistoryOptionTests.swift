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
    /// covers it, so tiers must be strictly ascending with non-negative spacing,
    /// and the deepest tier must reach the full retained duration — otherwise
    /// retained frames would be silently pruned as "beyond all tiers".
    /// Covers every recent-detail window, as the app passes the user's
    /// configured window rather than the default.
    func testEveryOptionProducesWellFormedRetentionTiers() throws {
        for option in RewindHistoryOption.allCases {
            for window in RecentTimelineWindow.allCases {
                try assertWellFormedTiers(
                    RetentionPolicy.rewindHistory(option, fullDetailWindow: window.rawValue).tiers,
                    option: option,
                    label: "\(option)/\(window)"
                )
            }
        }
    }

    private func assertWellFormedTiers(
        _ tiers: [RetentionTier],
        option: RewindHistoryOption,
        label: String
    ) throws {
        XCTAssertFalse(tiers.isEmpty, "\(label) has no tiers")

        for (previous, next) in zip(tiers, tiers.dropFirst()) {
            XCTAssertLessThan(
                previous.maxAge,
                next.maxAge,
                "\(label) tiers must be strictly ascending"
            )
        }
        for (index, tier) in tiers.enumerated() {
            if index == 0 {
                XCTAssertEqual(tier.minimumSpacing, 0, "\(label) must keep full detail")
            } else {
                XCTAssertGreaterThan(tier.minimumSpacing, 0, "\(label) has non-positive falloff spacing")
            }
        }

        let deepest = try XCTUnwrap(tiers.last)
        XCTAssertEqual(
            deepest.maxAge,
            option.retainedDuration,
            "\(label) deepest tier must cover the retained duration"
        )
    }
}
