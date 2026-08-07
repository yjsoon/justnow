import Foundation
import XCTest
@testable import JustNow

final class CapturePersistenceInstrumentationTests: XCTestCase {
    func testRecordsCaptureEncodingPersistenceAndMetadataMetrics() {
        let instrumentation = CapturePersistenceInstrumentation(
            shadowAnchorPolicy: ShadowAnchorPolicy(
                ordinaryInterval: 5,
                majorChangeHammingDistance: 4,
                majorChangeMinimumSpacing: 1
            )
        )
        let displayA = UUID()
        let displayB = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])

        instrumentation.recordCapturedFrame(displayID: displayA)
        instrumentation.recordCapturedFrame(displayID: displayB)
        instrumentation.recordPreTrimIngestQueueDepth(5)
        instrumentation.recordIngestQueueDepth(3)
        instrumentation.recordIngestQueueDepth(1)

        instrumentation.recordPerceptualObservation(hash: 0, timestamp: start, displayID: displayA)
        instrumentation.recordPerceptualObservation(
            hash: 0,
            timestamp: start.addingTimeInterval(1),
            displayID: displayA
        )
        instrumentation.recordPerceptualObservation(
            hash: 15,
            timestamp: start.addingTimeInterval(2),
            displayID: displayA
        )
        instrumentation.recordPerceptualObservation(
            hash: 0,
            timestamp: start.addingTimeInterval(2.5),
            displayID: displayA
        )
        instrumentation.recordPerceptualObservation(
            hash: 0,
            timestamp: start.addingTimeInterval(7.1),
            displayID: displayA
        )

        instrumentation.recordEncodedJPEG(jpeg, displayID: displayA)
        instrumentation.recordPersistedJPEG(jpeg, displayID: displayA)
        instrumentation.recordEncodedJPEG(jpeg, displayID: displayA)
        instrumentation.recordPersistedJPEG(jpeg, displayID: displayA)
        instrumentation.recordMetadataWrite(byteCount: 40)
        instrumentation.recordMetadataWrite(byteCount: 12)

        let snapshot = instrumentation.currentSnapshot()

        XCTAssertEqual(snapshot.capturedFrames, 2)
        XCTAssertEqual(snapshot.encodedFrames, 2)
        XCTAssertEqual(snapshot.persistedFrames, 2)
        XCTAssertEqual(snapshot.exactComparisonEligibleFrames, 2)
        XCTAssertEqual(snapshot.exactComparisonBaselineAvailableFrames, 1)
        XCTAssertEqual(snapshot.exactComparisonSkippedFrames, 0)
        XCTAssertEqual(snapshot.byteIdenticalEncodedFrames, 1)
        XCTAssertEqual(snapshot.perceptuallyEqualFrames, 2)
        XCTAssertEqual(snapshot.logicalJPEGBytesWritten, 8)
        XCTAssertEqual(snapshot.metadataBytesWritten, 52)
        XCTAssertEqual(snapshot.metadataTransactions, 2)
        XCTAssertEqual(snapshot.proposedOrdinaryAnchors, 2)
        XCTAssertEqual(snapshot.proposedMajorAnchors, 1)
        XCTAssertEqual(snapshot.maximumPreTrimIngestQueueDepth, 5)
        XCTAssertEqual(snapshot.maximumIngestQueueDepth, 3)
        XCTAssertEqual(snapshot.largestEncodedJPEGBytes, 4)
        XCTAssertEqual(snapshot.largestMetadataWriteBytes, 40)
        XCTAssertEqual(snapshot.maximumObservedDisplays, 2)
        XCTAssertEqual(snapshot.currentTrackedDisplays, 2)
    }

    func testExactEncodedComparisonIsScopedToDisplayAndSuccessfulPersistence() {
        let instrumentation = CapturePersistenceInstrumentation()
        let displayA = UUID()
        let displayB = UUID()
        let jpeg = Data([1, 2, 3])

        instrumentation.recordEncodedJPEG(jpeg, displayID: displayA)
        instrumentation.recordEncodedJPEG(jpeg, displayID: displayA)
        instrumentation.recordPersistedJPEG(jpeg, displayID: displayA)
        instrumentation.recordEncodedJPEG(jpeg, displayID: displayB)
        instrumentation.recordEncodedJPEG(jpeg, displayID: displayA)

        let snapshot = instrumentation.currentSnapshot()

        // The failed/not-yet-persisted attempts do not become comparison
        // baselines, and a display never compares against another display.
        XCTAssertEqual(snapshot.byteIdenticalEncodedFrames, 1)
        XCTAssertEqual(snapshot.encodedFrames, 4)
        XCTAssertEqual(snapshot.exactComparisonEligibleFrames, 4)
        XCTAssertEqual(snapshot.exactComparisonBaselineAvailableFrames, 1)
        XCTAssertEqual(snapshot.exactComparisonSkippedFrames, 0)
    }

    func testPromotionWriteReceiptIsIdempotentWithinAnEpochAndResetReopensItsToken() {
        let instrumentation = CapturePersistenceInstrumentation()
        let displayID = UUID()
        let firstReceipt = DurableJPEGWriteReceipt(
            writeToken: UUID(),
            frameID: UUID(),
            jpegData: Data([1, 2, 3]),
            displayID: displayID
        )
        let copiedReceipt = firstReceipt
        let secondReceipt = DurableJPEGWriteReceipt(
            writeToken: UUID(),
            frameID: UUID(),
            jpegData: Data([4, 5]),
            displayID: displayID
        )

        instrumentation.recordPersistedJPEG(receipt: firstReceipt)
        instrumentation.recordPersistedJPEG(receipt: copiedReceipt)
        instrumentation.recordPersistedJPEG(receipt: secondReceipt)

        var snapshot = instrumentation.currentSnapshot()
        XCTAssertEqual(snapshot.epoch, 0)
        XCTAssertEqual(snapshot.persistedFrames, 2)
        XCTAssertEqual(snapshot.logicalJPEGBytesWritten, 5)

        instrumentation.reset()
        instrumentation.recordPersistedJPEG(receipt: copiedReceipt)
        instrumentation.recordPersistedJPEG(receipt: copiedReceipt)

        snapshot = instrumentation.currentSnapshot()
        XCTAssertEqual(snapshot.epoch, 1)
        XCTAssertEqual(snapshot.persistedFrames, 1)
        XCTAssertEqual(snapshot.logicalJPEGBytesWritten, 3)
    }

    func testPromotionWriteReceiptLedgerRetainsOldestTokenForEntireEpoch() {
        let instrumentation = CapturePersistenceInstrumentation()
        let firstReceipt = DurableJPEGWriteReceipt(
            writeToken: UUID(),
            frameID: UUID(),
            jpegData: Data([1]),
            displayID: nil
        )
        instrumentation.recordPersistedJPEG(receipt: firstReceipt)

        for _ in 0..<4_096 {
            instrumentation.recordPersistedJPEG(
                receipt: DurableJPEGWriteReceipt(
                    writeToken: UUID(),
                    frameID: UUID(),
                    jpegData: Data([1]),
                    displayID: nil
                )
            )
        }
        instrumentation.recordPersistedJPEG(receipt: firstReceipt)

        let snapshot = instrumentation.currentSnapshot()
        XCTAssertEqual(snapshot.epoch, 0)
        XCTAssertEqual(snapshot.persistedFrames, 4_097)
        XCTAssertEqual(snapshot.logicalJPEGBytesWritten, 4_097)
    }

    func testRepositoryOutcomesExposeEveryStorageDispositionAndWriteEffect() {
        let instrumentation = CapturePersistenceInstrumentation()
        let jpeg = Data([1, 2, 3, 4])

        instrumentation.recordRepositorySaveOutcome(
            .durableFrame(metadataByteCount: 21),
            jpegData: jpeg,
            displayID: nil
        )
        instrumentation.recordRepositorySaveOutcome(
            .volatileFrame,
            jpegData: jpeg,
            displayID: nil
        )
        instrumentation.recordRepositorySaveOutcome(
            .duplicateFrame,
            jpegData: jpeg,
            displayID: nil
        )
        instrumentation.recordRepositorySaveOutcome(
            .spanCheckpoint(metadataByteCount: 8),
            jpegData: jpeg,
            displayID: nil
        )

        let snapshot = instrumentation.currentSnapshot()
        XCTAssertEqual(snapshot.durableRepositorySaves, 1)
        XCTAssertEqual(snapshot.volatileRepositorySaves, 1)
        XCTAssertEqual(snapshot.duplicateRepositorySaves, 1)
        XCTAssertEqual(snapshot.spanCheckpointRepositorySaves, 1)
        XCTAssertEqual(snapshot.persistedFrames, 1)
        XCTAssertEqual(snapshot.logicalJPEGBytesWritten, 4)
        XCTAssertEqual(snapshot.metadataTransactions, 2)
        XCTAssertEqual(snapshot.metadataBytesWritten, 29)
        XCTAssertEqual(snapshot.largestMetadataWriteBytes, 21)
    }

    func testOversizedJPEGsAreExplicitlySkippedFromExactComparison() {
        let instrumentation = CapturePersistenceInstrumentation()
        let oversizedJPEG = Data(
            repeating: 0xA5,
            count: CapturePersistenceInstrumentation.maximumComparableJPEGBytes + 1
        )

        instrumentation.recordEncodedJPEG(oversizedJPEG, displayID: nil)
        instrumentation.recordPersistedJPEG(oversizedJPEG, displayID: nil)
        instrumentation.recordEncodedJPEG(oversizedJPEG, displayID: nil)

        let snapshot = instrumentation.currentSnapshot()
        XCTAssertEqual(snapshot.encodedFrames, 2)
        XCTAssertEqual(snapshot.exactComparisonEligibleFrames, 0)
        XCTAssertEqual(snapshot.exactComparisonBaselineAvailableFrames, 0)
        XCTAssertEqual(snapshot.exactComparisonSkippedFrames, 2)
        XCTAssertEqual(snapshot.byteIdenticalEncodedFrames, 0)
    }

    func testResetStartsANewEpochAndDiscardsComparisonAndAnchorBaselines() {
        let instrumentation = CapturePersistenceInstrumentation()
        let displayID = UUID()
        let jpeg = Data([1, 2, 3])
        let timestamp = Date(timeIntervalSince1970: 1_000)

        instrumentation.recordCapturedFrame(displayID: displayID)
        instrumentation.recordPerceptualObservation(hash: 42, timestamp: timestamp, displayID: displayID)
        instrumentation.recordEncodedJPEG(jpeg, displayID: displayID)
        instrumentation.recordPersistedJPEG(jpeg, displayID: displayID)
        instrumentation.reset()
        instrumentation.recordEncodedJPEG(jpeg, displayID: displayID)

        let snapshot = instrumentation.currentSnapshot()
        XCTAssertEqual(snapshot.epoch, 1)
        XCTAssertEqual(snapshot.capturedFrames, 0)
        XCTAssertEqual(snapshot.proposedOrdinaryAnchors, 0)
        XCTAssertEqual(snapshot.exactComparisonEligibleFrames, 1)
        XCTAssertEqual(snapshot.exactComparisonBaselineAvailableFrames, 0)
        XCTAssertEqual(snapshot.byteIdenticalEncodedFrames, 0)
    }

    func testDisplayStateUsesABoundedLRU() {
        let instrumentation = CapturePersistenceInstrumentation()
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let displays = (0...CapturePersistenceInstrumentation.maximumTrackedDisplays).map { _ in UUID() }

        for (index, displayID) in displays.enumerated() {
            instrumentation.recordCapturedFrame(displayID: displayID)
            instrumentation.recordPerceptualObservation(
                hash: UInt64(index),
                timestamp: timestamp,
                displayID: displayID
            )
        }

        let snapshot = instrumentation.currentSnapshot()
        XCTAssertEqual(snapshot.currentTrackedDisplays, CapturePersistenceInstrumentation.maximumTrackedDisplays)
        XCTAssertEqual(snapshot.maximumObservedDisplays, CapturePersistenceInstrumentation.maximumTrackedDisplays)
        XCTAssertEqual(snapshot.displayStateEvictions, 1)
    }

    func testObserverRemainsSafeUnderConcurrentRecording() {
        let instrumentation = CapturePersistenceInstrumentation()
        let displayIDs = (0..<4).map { _ in UUID() }

        DispatchQueue.concurrentPerform(iterations: 200) { index in
            let displayID = displayIDs[index % displayIDs.count]
            instrumentation.recordCapturedFrame(displayID: displayID)
            instrumentation.recordPerceptualObservation(
                hash: UInt64(index % 7),
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                displayID: displayID
            )
        }

        let snapshot = instrumentation.currentSnapshot()
        XCTAssertEqual(snapshot.capturedFrames, 200)
        XCTAssertEqual(snapshot.currentTrackedDisplays, displayIDs.count)
        XCTAssertEqual(snapshot.displayStateEvictions, 0)
    }

    func testDiagnosticsLineContainsAggregateMeasurementCoverage() {
        let instrumentation = CapturePersistenceInstrumentation()
        instrumentation.recordCapturedFrame(displayID: nil)
        instrumentation.recordEncodedJPEG(Data([1]), displayID: nil)
        instrumentation.recordMetadataWrite(byteCount: 12)

        let line = CapturePersistenceInstrumentationDiagnosticsFormat.line(
            instrumentation.currentSnapshot()
        )

        XCTAssertTrue(line.contains("epoch=0"))
        XCTAssertTrue(line.contains("repository{durable=0 volatile=0 duplicate=0 checkpoint=0}"))
        XCTAssertTrue(line.contains("exact{eligible=1 baseline=0 identical=0 skipped=0}"))
        XCTAssertTrue(line.contains("queue{preTrimHigh=0 retainedHigh=0 asyncDropped=0"))
        XCTAssertFalse(line.contains("displayID"))
    }
}
