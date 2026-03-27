import XCTest
@testable import JustNow

final class SearchTelemetryTests: XCTestCase {

    private func makeTelemetry() -> SearchTelemetry {
        SearchTelemetry()
    }

    // MARK: - Empty state

    func testEmptySnapshotHasZeroValues() async {
        let telemetry = makeTelemetry()
        let snap = await telemetry.snapshot()

        XCTAssertEqual(snap.queueDepth, 0)
        XCTAssertEqual(snap.queueCapacity, 0)
        XCTAssertEqual(snap.ocrPerSecond, 0, accuracy: 0.001)
        XCTAssertEqual(snap.averageOCRDuration, 0)
        XCTAssertEqual(snap.p95OCRDuration, 0)
        XCTAssertEqual(snap.averageIndexLag, 0)
        XCTAssertEqual(snap.warmSearchP50, 0)
        XCTAssertEqual(snap.warmSearchCount, 0)
        XCTAssertEqual(snap.coldSearchP50, 0)
        XCTAssertEqual(snap.coldSearchCount, 0)
    }

    // MARK: - Queue depth

    func testRecordQueueDepthUpdatesSnapshot() async {
        let telemetry = makeTelemetry()
        await telemetry.recordQueueDepth(depth: 5, capacity: 20)

        let snap = await telemetry.snapshot()
        XCTAssertEqual(snap.queueDepth, 5)
        XCTAssertEqual(snap.queueCapacity, 20)
    }

    func testNegativeQueueDepthIsClampedToZero() async {
        let telemetry = makeTelemetry()
        await telemetry.recordQueueDepth(depth: -3, capacity: -1)

        let snap = await telemetry.snapshot()
        XCTAssertEqual(snap.queueDepth, 0)
        XCTAssertEqual(snap.queueCapacity, 0)
    }

    // MARK: - OCR recording

    func testRecordBackgroundOCRUpdatesSnapshot() async {
        let telemetry = makeTelemetry()
        await telemetry.recordBackgroundOCR(duration: 0.5, indexLag: 2.0)
        await telemetry.recordBackgroundOCR(duration: 1.5, indexLag: 4.0)

        let snap = await telemetry.snapshot()
        XCTAssertEqual(snap.averageOCRDuration, 1.0, accuracy: 0.001)
        XCTAssertEqual(snap.averageIndexLag, 3.0, accuracy: 0.001)
        XCTAssertGreaterThan(snap.ocrPerSecond, 0)
    }

    func testNegativeDurationsAreClampedToZero() async {
        let telemetry = makeTelemetry()
        await telemetry.recordBackgroundOCR(duration: -1, indexLag: -5)

        let snap = await telemetry.snapshot()
        XCTAssertEqual(snap.averageOCRDuration, 0)
        XCTAssertEqual(snap.averageIndexLag, 0)
    }

    // MARK: - Search recording

    func testWarmSearchRecording() async {
        let telemetry = makeTelemetry()
        await telemetry.recordSearch(
            duration: 0.05, wasCold: false,
            totalFrames: 100, uncachedFrames: 0, matches: 5, ocrRuns: 0, loadFailures: 0
        )

        let snap = await telemetry.snapshot()
        XCTAssertEqual(snap.warmSearchCount, 1)
        XCTAssertEqual(snap.coldSearchCount, 0)
        XCTAssertEqual(snap.warmSearchP50, 0.05, accuracy: 0.001)
    }

    func testColdSearchRecording() async {
        let telemetry = makeTelemetry()
        await telemetry.recordSearch(
            duration: 0.3, wasCold: true,
            totalFrames: 50, uncachedFrames: 50, matches: 2, ocrRuns: 50, loadFailures: 1
        )

        let snap = await telemetry.snapshot()
        XCTAssertEqual(snap.coldSearchCount, 1)
        XCTAssertEqual(snap.warmSearchCount, 0)
        XCTAssertEqual(snap.coldSearchP50, 0.3, accuracy: 0.001)
    }

    // MARK: - Percentile accuracy

    func testP95WithKnownDistribution() async {
        let telemetry = makeTelemetry()
        // Record 20 OCR samples: 0.1, 0.2, ..., 2.0
        for i in 1...20 {
            await telemetry.recordBackgroundOCR(duration: Double(i) * 0.1, indexLag: 0)
        }

        let snap = await telemetry.snapshot()
        // p95 of [0.1..2.0] at index floor(19 * 0.95) = 18 → sorted[18] = 1.9
        XCTAssertEqual(snap.p95OCRDuration, 1.9, accuracy: 0.15)
    }

    // MARK: - SearchTelemetrySnapshot.empty

    func testEmptySnapshotConstant() {
        let snap = SearchTelemetrySnapshot.empty
        XCTAssertEqual(snap.queueDepth, 0)
        XCTAssertEqual(snap.ocrPerSecond, 0)
        XCTAssertEqual(snap.warmSearchCount, 0)
        XCTAssertEqual(snap.coldSearchCount, 0)
    }
}
