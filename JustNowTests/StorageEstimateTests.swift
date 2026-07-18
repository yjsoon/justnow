import XCTest
@testable import JustNow

final class StorageEstimateTests: XCTestCase {
    private let displayID = UUID()

    private func sample(
        displayID: UUID? = nil,
        storedBytes: Int64,
        frameCount: Int
    ) -> FrameStorageSample {
        FrameStorageSample(
            displayID: displayID,
            storedBytes: storedBytes,
            frameCount: frameCount
        )
    }

    func testMaximumSettingsProjectElevenThousandSevenHundredSixtyOneFramesPerDisplay() {
        let policy = RetentionPolicy.rewindHistory(
            .twentyFourHours,
            captureInterval: 0.25,
            fullDetailWindow: 30 * 60
        )

        // The first tier includes the frame at age zero, then:
        // 30 min × 4 fps + 30 min × 1 fps + 23 hr × 1/30 fps.
        XCTAssertEqual(
            StorageEstimate.projectedFrameCountPerDisplay(
                policy: policy,
                captureInterval: 0.25
            ),
            11_761
        )
    }

    func testEstimateUsesAverageSavedFrameSize() {
        let policy = RetentionPolicy(tiers: [
            RetentionTier(maxAge: 10, minimumSpacing: 0)
        ])

        XCTAssertEqual(
            StorageEstimate.projectedBytes(
                policy: policy,
                captureInterval: 1,
                samples: [sample(displayID: displayID, storedBytes: 5_000, frameCount: 10)],
                connectedDisplayIDs: [displayID]
            ),
            5_500
        )
    }

    func testEstimateIncludesEveryDisplay() {
        let policy = RetentionPolicy(tiers: [
            RetentionTier(maxAge: 10, minimumSpacing: 1)
        ])

        let secondDisplayID = UUID()
        XCTAssertEqual(
            StorageEstimate.projectedBytes(
                policy: policy,
                captureInterval: 1,
                samples: [
                    sample(displayID: displayID, storedBytes: 5_000, frameCount: 10),
                    sample(displayID: secondDisplayID, storedBytes: 10_000, frameCount: 10)
                ],
                connectedDisplayIDs: [displayID, secondDisplayID]
            ),
            16_500
        )
    }

    func testEstimateFallsBackToGlobalAverageForANewDisplay() {
        let policy = RetentionPolicy(tiers: [
            RetentionTier(maxAge: 10, minimumSpacing: 1)
        ])

        XCTAssertEqual(
            StorageEstimate.projectedBytes(
                policy: policy,
                captureInterval: 1,
                samples: [sample(storedBytes: 5_000, frameCount: 10)],
                connectedDisplayIDs: [displayID]
            ),
            5_500
        )
    }

    func testEstimateUsesCaptureCadenceWhenItIsSlowerThanTierSpacing() {
        let policy = RetentionPolicy(tiers: [
            RetentionTier(maxAge: 20, minimumSpacing: 1)
        ])

        XCTAssertEqual(
            StorageEstimate.projectedFrameCountPerDisplay(
                policy: policy,
                captureInterval: 5
            ),
            5
        )
    }

    func testFirstTierUsesFloorForCadencesThatDoNotDivideItsDuration() {
        let policy = RetentionPolicy(tiers: [
            RetentionTier(maxAge: 30 * 60, minimumSpacing: 0)
        ])

        XCTAssertEqual(
            StorageEstimate.projectedFrameCountPerDisplay(
                policy: policy,
                captureInterval: 1.75
            ),
            1_029
        )
    }

    func testEstimateWaitsForEnoughSavedFrames() {
        let policy = RetentionPolicy(tiers: [
            RetentionTier(maxAge: 10, minimumSpacing: 1)
        ])

        XCTAssertNil(
            StorageEstimate.projectedBytes(
                policy: policy,
                captureInterval: 1,
                samples: [sample(
                    storedBytes: 9_000,
                    frameCount: StorageEstimate.minimumSampleFrameCount - 1
                )],
                connectedDisplayIDs: [displayID]
            )
        )
    }

    func testEstimateRejectsEmptyStorage() {
        let policy = RetentionPolicy(tiers: [
            RetentionTier(maxAge: 10, minimumSpacing: 1)
        ])

        XCTAssertNil(
            StorageEstimate.projectedBytes(
                policy: policy,
                captureInterval: 1,
                samples: [sample(
                    storedBytes: 0,
                    frameCount: StorageEstimate.minimumSampleFrameCount
                )],
                connectedDisplayIDs: [displayID]
            )
        )
    }

    func testEstimateRejectsMissingDisplaysAndEmptyPolicies() {
        let policy = RetentionPolicy(tiers: [
            RetentionTier(maxAge: 10, minimumSpacing: 1)
        ])

        XCTAssertNil(
            StorageEstimate.projectedBytes(
                policy: policy,
                captureInterval: 1,
                samples: [sample(storedBytes: 5_000, frameCount: 10)],
                connectedDisplayIDs: []
            )
        )
        XCTAssertNil(
            StorageEstimate.projectedBytes(
                policy: RetentionPolicy(tiers: []),
                captureInterval: 1,
                samples: [sample(storedBytes: 5_000, frameCount: 10)],
                connectedDisplayIDs: [displayID]
            )
        )
    }

    func testEstimateRejectsValuesThatWouldOverflowInt64() {
        let policy = RetentionPolicy(tiers: [
            RetentionTier(maxAge: 10, minimumSpacing: 0)
        ])

        XCTAssertNil(
            StorageEstimate.projectedBytes(
                policy: policy,
                captureInterval: 0.25,
                samples: [sample(storedBytes: .max, frameCount: 10)],
                connectedDisplayIDs: (0..<10).map { _ in UUID() }
            )
        )
    }

    func testProjectedFrameCountSaturatesInsteadOfOverflowingInt() {
        let policy = RetentionPolicy(tiers: [
            RetentionTier(maxAge: .greatestFiniteMagnitude, minimumSpacing: 0)
        ])

        XCTAssertEqual(
            StorageEstimate.projectedFrameCountPerDisplay(
                policy: policy,
                captureInterval: 0.25
            ),
            Int.max
        )
    }
}
