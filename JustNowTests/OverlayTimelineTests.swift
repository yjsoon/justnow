import XCTest
@testable import JustNow

final class OverlayTimelineTests: XCTestCase {
    func testResolveTimelineMarkerPositionUsesNearestFrame() throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let frames = makeFrames(offsets: [1_200, 600, 60], now: now)

        let position = try XCTUnwrap(resolveTimelineMarkerPosition(
            frames: frames,
            targetAge: 480,
            now: now
        ))

        XCTAssertEqual(position, 0.5, accuracy: 0.000_1)
    }

    func testTimelineLandmarkMarkersIncludeRecentWindowMarker() throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let frames = makeFrames(offsets: [1_800, 900, 300, 60], now: now)

        let markers = timelineLandmarkMarkers(
            frames: frames,
            recentWindow: 300,
            now: now
        )

        let recentMarker = try XCTUnwrap(markers.first { $0.targetAge == 300 })

        XCTAssertEqual(markers.map(\.targetAge), [1_800, 600, 300])
        XCTAssertEqual(recentMarker.frameIndex, 2)
        XCTAssertEqual(recentMarker.label, "5min")
        XCTAssertEqual(recentMarker.position, 2.0 / 3.0, accuracy: 0.000_1)
    }

    func testTimelineColourSegmentsSplitAtBorder() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let frames = makeFrames(offsets: [1_200, 600], now: now)

        let segments = timelineColourSegments(frames: frames, borderPosition: 0.25)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].start, 0, accuracy: 0.000_1)
        XCTAssertEqual(segments[0].end, 0.25, accuracy: 0.000_1)
        XCTAssertEqual(segments[1].start, 0.25, accuracy: 0.000_1)
        XCTAssertEqual(segments[1].end, 1, accuracy: 0.000_1)
    }

    func testResolveTimelineMarkerPositionRequiresAtLeastTwoFrames() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        XCTAssertNil(resolveTimelineMarkerPosition(frames: [], targetAge: 60, now: now))
        XCTAssertNil(
            resolveTimelineMarkerPosition(
                frames: makeFrames(offsets: [60], now: now),
                targetAge: 60,
                now: now
            )
        )
    }

    func testResolveTimelineMarkerPositionClampsTargetsBeyondHistoryEnds() throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let frames = makeFrames(offsets: [600, 300, 60], now: now)

        // Older than the oldest frame snaps to the start of the timeline.
        let tooOld = try XCTUnwrap(
            resolveTimelineMarkerPosition(frames: frames, targetAge: 5_000, now: now)
        )
        XCTAssertEqual(tooOld, 0, accuracy: 0.000_1)

        // Newer than the newest frame snaps to the end.
        let tooNew = try XCTUnwrap(
            resolveTimelineMarkerPosition(frames: frames, targetAge: 0, now: now)
        )
        XCTAssertEqual(tooNew, 1, accuracy: 0.000_1)
    }

    func testTimelineColourSegmentsWithoutUsableBorderProduceSingleFill() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let frames = makeFrames(offsets: [1_200, 600], now: now)

        for border in [nil, CGFloat(0)] {
            let segments = timelineColourSegments(frames: frames, borderPosition: border)
            XCTAssertEqual(segments.count, 1)
            XCTAssertEqual(segments[0].start, 0)
            XCTAssertEqual(segments[0].end, 1)
        }
    }

    func testTimelineColourSegmentsDropEmptySegmentWhenBorderIsAtTheEnd() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let frames = makeFrames(offsets: [1_200, 600], now: now)

        let segments = timelineColourSegments(frames: frames, borderPosition: 1)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].start, 0)
        XCTAssertEqual(segments[0].end, 1)
    }

    func testTimelineColourSegmentsRequireAtLeastTwoFrames() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        XCTAssertTrue(timelineColourSegments(frames: [], borderPosition: 0.5).isEmpty)
        XCTAssertTrue(
            timelineColourSegments(
                frames: makeFrames(offsets: [60], now: now),
                borderPosition: 0.5
            ).isEmpty
        )
    }

    func testTimelineMarkerLabelBoundaries() {
        let reference = Date(timeIntervalSinceReferenceDate: 1_000_000)

        XCTAssertEqual(formatTimelineMarkerLabel(targetAge: 59 * 60, targetDate: reference), "59min")
        XCTAssertEqual(formatTimelineMarkerLabel(targetAge: 60 * 60, targetDate: reference), "1h")
        XCTAssertEqual(formatTimelineMarkerLabel(targetAge: 2 * 60 * 60, targetDate: reference), "2h")
    }

    func testFormatRelativeTimeClampsFutureTimestampsToZero() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        XCTAssertEqual(formatRelativeTime(now.addingTimeInterval(30), now: now), "0s ago")
    }

    func testFormatRelativeTimeBoundaries() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        XCTAssertEqual(formatRelativeTime(now, now: now), "0s ago")
        XCTAssertEqual(formatRelativeTime(now.addingTimeInterval(-59), now: now), "59s ago")
        XCTAssertEqual(formatRelativeTime(now.addingTimeInterval(-60), now: now), "1m 0s ago")
        XCTAssertEqual(formatRelativeTime(now.addingTimeInterval(-3_599), now: now), "59m 59s ago")
        XCTAssertEqual(formatRelativeTime(now.addingTimeInterval(-3_600), now: now), "1h 0m 0s ago")
        XCTAssertEqual(formatRelativeTime(now.addingTimeInterval(-7_199), now: now), "1h 59m 59s ago")
    }

    func testFormatRelativeTimeCalendarBranchesUseInjectedNow() throws {
        // Midday avoids timezone day-boundary effects; assert structural
        // properties rather than locale-dependent clock strings.
        let now = try XCTUnwrap(
            Calendar.current.date(from: DateComponents(year: 2024, month: 6, day: 15, hour: 12))
        )

        let today = formatRelativeTime(now.addingTimeInterval(-3 * 3_600), now: now)
        XCTAssertFalse(today.contains("ago"))
        XCTAssertFalse(today.contains("Yesterday"))

        let yesterday = formatRelativeTime(now.addingTimeInterval(-24 * 3_600), now: now)
        XCTAssertTrue(yesterday.hasPrefix("Yesterday"))

        let dayLabel = formatRelativeTime(now.addingTimeInterval(-3 * 86_400), now: now)
        XCTAssertFalse(dayLabel.contains("ago"))
        XCTAssertFalse(dayLabel.contains("Yesterday"))
    }

    private func makeFrames(offsets: [TimeInterval], now: Date) -> [StoredFrame] {
        offsets.map { offset in
            StoredFrame(
                id: UUID(),
                timestamp: now.addingTimeInterval(-offset),
                hash: 0,
                displayID: nil,
                displayName: nil
            )
        }
    }
}
