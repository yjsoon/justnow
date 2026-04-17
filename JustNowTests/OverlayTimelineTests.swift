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
