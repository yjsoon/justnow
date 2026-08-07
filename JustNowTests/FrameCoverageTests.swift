import Foundation
import XCTest
@testable import JustNow

final class FrameCoverageTests: XCTestCase {
    func testIntervalUnionNormalisesReversedBoundsAndPreservesGaps() throws {
        let entries = [
            makeEntry(start: 0, end: 10),
            makeEntry(start: 10, end: 20),
            makeEntry(start: 30, end: 40),
            makeEntry(start: 50, end: 45)
        ]

        let statistics = FrameCoverageCalculator.intervalStatistics(for: entries)

        XCTAssertEqual(statistics.oldest, date(0))
        XCTAssertEqual(statistics.newest, date(50))
        XCTAssertEqual(statistics.coveredSeconds, 35, accuracy: 0.000_001)
        XCTAssertTrue(statistics.hasGaps)
    }

    func testCoverageRemainsSeparatePerDisplayAndLabelsLegacyHistory() throws {
        let firstID = UUID()
        let secondID = UUID()
        let values = FrameCoverageCalculator.calculate(
            durable: [
                makeEntry(start: 0, end: 10, displayID: firstID, displayName: "Built-in"),
                makeEntry(start: 0, end: 20, displayID: secondID, displayName: "Desk"),
                makeEntry(start: 5, end: 12, displayID: nil, displayName: nil)
            ],
            volatile: []
        )

        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(values.first { $0.displayID == firstID }?.combined.coveredSeconds, 10)
        XCTAssertEqual(values.first { $0.displayID == secondID }?.combined.coveredSeconds, 20)
        let legacy = try XCTUnwrap(values.first { $0.displayID == nil })
        XCTAssertEqual(legacy.displayLabel, "Legacy history")
        XCTAssertEqual(legacy.combined.coveredSeconds, 7)
    }

    func testMirroredSourcesDoNotDoubleCountAndCombinedUsesNewerLogicalOverlay() throws {
        let spanID = UUID()
        let displayID = UUID()
        let durable = makeEntry(start: 0, end: 10, spanID: spanID, displayID: displayID)
        let volatile = makeEntry(start: 0, end: 20, spanID: spanID, displayID: displayID)
        let mergedOverlay = makeEntry(start: 0, end: 30, spanID: spanID, displayID: displayID)

        let value = try XCTUnwrap(FrameCoverageCalculator.calculate(
            durable: [durable],
            volatile: [volatile],
            combined: [mergedOverlay]
        ).first)

        XCTAssertEqual(value.durable.coveredSeconds, 10)
        XCTAssertEqual(value.volatile.coveredSeconds, 20)
        XCTAssertEqual(value.combined.coveredSeconds, 30)
        XCTAssertEqual(value.combined.newest, date(30))
        XCTAssertFalse(value.combined.hasGaps)
    }

    private func makeEntry(
        start: TimeInterval,
        end: TimeInterval,
        spanID: UUID = UUID(),
        displayID: UUID? = UUID(),
        displayName: String? = "Display"
    ) -> TimelineEntry {
        let frameID = UUID()
        return TimelineEntry(
            span: TimelineSpan(
                id: spanID,
                frameID: frameID,
                sessionID: UUID(),
                startedAt: date(start),
                observedThroughAt: date(end),
                observationCount: 1,
                displayID: displayID,
                displayName: displayName
            ),
            frame: StoredFrame(
                id: frameID,
                timestamp: date(start),
                hash: 1,
                displayID: displayID,
                displayName: displayName
            )
        )
    }

    private func date(_ value: TimeInterval) -> Date {
        Date(timeIntervalSince1970: value)
    }
}
