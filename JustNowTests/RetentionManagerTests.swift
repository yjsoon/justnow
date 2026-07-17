import Foundation
import XCTest
@testable import JustNow

@MainActor
final class RetentionManagerTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testKeepsOldestFrameInEachSpacingWindowWithinTier() {
        let manager = RetentionManager(
            policy: RetentionPolicy(tiers: [RetentionTier(maxAge: 100, minimumSpacing: 10)])
        )
        let frames = makeFrames(agesAscendingOldestFirst: [95, 90, 84, 50])

        let pruned = manager.framesToPrune(frames: frames, currentTime: now)

        // 95 anchors the chain; 90 is only 5s later so it is compacted away;
        // 84 restarts the spacing window; 50 is far enough from 84.
        XCTAssertEqual(pruned, [frames[1].id])
    }

    func testFramesOlderThanDeepestTierAreAlwaysPruned() {
        let manager = RetentionManager(
            policy: RetentionPolicy(tiers: [RetentionTier(maxAge: 100, minimumSpacing: 1)])
        )
        let frames = makeFrames(agesAscendingOldestFirst: [500, 200, 50])

        let pruned = manager.framesToPrune(frames: frames, currentTime: now)

        XCTAssertEqual(pruned, [frames[0].id, frames[1].id])
    }

    func testFrameExactlyAtTierBoundaryBelongsToThatTier() {
        let manager = RetentionManager(
            policy: RetentionPolicy(tiers: [RetentionTier(maxAge: 100, minimumSpacing: 1)])
        )
        let frames = makeFrames(agesAscendingOldestFirst: [100])

        XCTAssertTrue(manager.framesToPrune(frames: frames, currentTime: now).isEmpty)
    }

    func testFutureTimestampedFramesFallIntoFirstTierInsteadOfBeingDropped() {
        let manager = RetentionManager(
            policy: RetentionPolicy(tiers: [RetentionTier(maxAge: 100, minimumSpacing: 1)])
        )
        // Clock rolled back: the frame is 30s "in the future".
        let frames = makeFrames(agesAscendingOldestFirst: [-30])

        XCTAssertTrue(manager.framesToPrune(frames: frames, currentTime: now).isEmpty)
    }

    func testEmptyInputPrunesNothing() {
        let manager = RetentionManager()

        XCTAssertTrue(manager.framesToPrune(frames: [], currentTime: now).isEmpty)
    }

    func testEachTierAppliesItsOwnSpacing() {
        let manager = RetentionManager(
            policy: RetentionPolicy(tiers: [
                RetentionTier(maxAge: 60, minimumSpacing: 1),
                RetentionTier(maxAge: 600, minimumSpacing: 30)
            ])
        )
        // Two archive-tier frames 10s apart (compacted to one) and two
        // recent-tier frames 10s apart (both kept).
        let frames = makeFrames(agesAscendingOldestFirst: [300, 290, 40, 30])

        let pruned = manager.framesToPrune(frames: frames, currentTime: now)

        XCTAssertEqual(pruned, [frames[1].id])
    }

    func testUpdatePolicyTakesEffectImmediately() {
        let manager = RetentionManager(
            policy: RetentionPolicy(tiers: [RetentionTier(maxAge: 1_000, minimumSpacing: 1)])
        )
        let frames = makeFrames(agesAscendingOldestFirst: [500, 50])

        XCTAssertTrue(manager.framesToPrune(frames: frames, currentTime: now).isEmpty)

        manager.updatePolicy(
            RetentionPolicy(tiers: [RetentionTier(maxAge: 100, minimumSpacing: 1)])
        )

        XCTAssertEqual(manager.framesToPrune(frames: frames, currentTime: now), [frames[0].id])
    }

    func testHighFidelityDefaultFallsOffProgressively() {
        let policy = RetentionPolicy.rewindHistory(
            .twentyFourHours,
            captureInterval: 0.25,
            fullDetailWindow: 15 * 60
        )

        XCTAssertEqual(
            policy.tiers,
            [
                RetentionTier(maxAge: 15 * 60, minimumSpacing: 0),
                RetentionTier(maxAge: 30 * 60, minimumSpacing: 1),
                RetentionTier(maxAge: 60 * 60, minimumSpacing: 5),
                RetentionTier(maxAge: 24 * 60 * 60, minimumSpacing: 30),
            ]
        )
    }

    func testTwoHourWindowReachesArchiveFalloff() {
        let policy = RetentionPolicy.rewindHistory(
            .twoHours,
            captureInterval: 0.25,
            fullDetailWindow: 15 * 60
        )

        XCTAssertEqual(
            policy.tiers,
            [
                RetentionTier(maxAge: 15 * 60, minimumSpacing: 0),
                RetentionTier(maxAge: 30 * 60, minimumSpacing: 1),
                RetentionTier(maxAge: 60 * 60, minimumSpacing: 5),
                RetentionTier(maxAge: 2 * 60 * 60, minimumSpacing: 20),
            ]
        )
    }

    func testThirtyMinuteFullDetailWindowDoesNotCreateEmptyTiers() {
        let policy = RetentionPolicy.rewindHistory(
            .thirtyMinutes,
            captureInterval: 0.25,
            fullDetailWindow: 30 * 60
        )

        XCTAssertEqual(
            policy.tiers,
            [
                RetentionTier(maxAge: 30 * 60, minimumSpacing: 0),
                RetentionTier(maxAge: 60 * 60, minimumSpacing: 30),
            ]
        )
    }

    func testCaptureIntervalChangesDoNotRecompactExistingFalloffTiers() {
        let fastPolicy = RetentionPolicy.rewindHistory(
            .twentyFourHours,
            captureInterval: 0.25,
            fullDetailWindow: 15 * 60
        )
        let slowPolicy = RetentionPolicy.rewindHistory(
            .twentyFourHours,
            captureInterval: 5,
            fullDetailWindow: 15 * 60
        )

        XCTAssertEqual(fastPolicy.tiers, slowPolicy.tiers)
        XCTAssertEqual(slowPolicy.tiers.map(\.minimumSpacing), [0, 1, 5, 30])
    }

    func testFullDetailTierKeepsFramesCloserThanCaptureCadence() {
        let manager = RetentionManager(
            policy: .rewindHistory(
                .twentyFourHours,
                captureInterval: 0.25,
                fullDetailWindow: 15 * 60
            )
        )
        let frames = makeFrames(agesAscendingOldestFirst: [1, 0.8])

        XCTAssertTrue(manager.framesToPrune(frames: frames, currentTime: now).isEmpty)
    }

    func testSpacingIsAppliedIndependentlyPerDisplay() {
        let displayA = UUID()
        let displayB = UUID()
        let manager = RetentionManager(
            policy: RetentionPolicy(tiers: [RetentionTier(maxAge: 100, minimumSpacing: 10)])
        )
        let frames = [
            makeFrame(age: 50, displayID: displayA),
            makeFrame(age: 49, displayID: displayB),
            makeFrame(age: 45, displayID: displayA),
            makeFrame(age: 44, displayID: displayB),
        ]

        XCTAssertEqual(
            manager.framesToPrune(frames: frames, currentTime: now),
            [frames[2].id, frames[3].id]
        )
    }

    func testInvalidCaptureIntervalsResolveToSafeFalloff() {
        for interval in [Double.nan, .infinity, -.infinity, 0, -1, 100] {
            let policy = RetentionPolicy.rewindHistory(
                .twentyFourHours,
                captureInterval: interval,
                fullDetailWindow: 15 * 60
            )

            XCTAssertTrue(policy.tiers.allSatisfy { $0.minimumSpacing.isFinite })
            XCTAssertEqual(policy.tiers.first?.minimumSpacing, 0)
        }
    }

    private func makeFrames(agesAscendingOldestFirst ages: [TimeInterval]) -> [StoredFrame] {
        ages.map { makeFrame(age: $0) }
    }

    private func makeFrame(age: TimeInterval, displayID: UUID? = nil) -> StoredFrame {
        StoredFrame(
            id: UUID(),
            timestamp: now.addingTimeInterval(-age),
            hash: 1,
            displayID: displayID,
            displayName: nil
        )
    }
}
