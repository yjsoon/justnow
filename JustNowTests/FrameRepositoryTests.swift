import CoreGraphics
import Foundation
import SQLite3
import XCTest
@testable import JustNow

final class FrameRepositoryTests: XCTestCase {
    private var directory: URL!
    private var exportDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FrameRepositoryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        exportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FrameRepositoryExports-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: exportDirectory)
        try super.tearDownWithError()
    }

    func testDiskRepositoryPreservesStableIDAndExactJPEGThroughResolutionAndExport() async throws {
        let instrumentation = CapturePersistenceInstrumentation()
        let store = try FrameStore(
            directory: directory,
            instrumentation: instrumentation,
            screenshotsDirectory: exportDirectory
        )
        let repository = DiskFrameRepository(frameStore: store)
        let image = try makeImage(width: 24, height: 16)
        let jpegData = try XCTUnwrap(ImageEncoder.jpegData(from: image, quality: 0.73))
        let frame = StoredFrame(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_234.5),
            hash: 42,
            displayID: UUID(),
            displayName: "Test Display"
        )
        _ = try await repository.beginCaptureSession(at: frame.timestamp)

        let result = try await repository.recordEncodedCapture(frame, jpegData: jpegData)

        let payloadURL = directory
            .appendingPathComponent("frames", isDirectory: true)
            .appendingPathComponent("\(frame.id.uuidString).jpg")
        XCTAssertEqual(try Data(contentsOf: payloadURL), jpegData)
        let orderedFrames = await repository.orderedFrames()
        XCTAssertEqual(orderedFrames, [frame])
        let timeline = await repository.orderedTimeline()
        XCTAssertEqual(timeline.count, 1)
        XCTAssertEqual(timeline.first?.frame, frame)
        XCTAssertEqual(timeline.first?.span.frameID, frame.id)
        XCTAssertEqual(timeline.first?.span.startedAt, frame.timestamp)
        XCTAssertEqual(timeline.first?.span.observedThroughAt, frame.timestamp)
        XCTAssertEqual(timeline.first?.span.observationCount, 1)

        let fullImage = try await repository.loadFullImage(id: frame.id)
        XCTAssertEqual(fullImage.width, image.width)
        XCTAssertEqual(fullImage.height, image.height)

        let searchImage = try await repository.loadSearchIndexImage(id: frame.id, maxPixelSize: 8)
        XCTAssertLessThanOrEqual(max(searchImage.width, searchImage.height), 8)
        let thumbnail = await repository.loadThumbnail(id: frame.id)
        XCTAssertEqual(thumbnail?.width, image.width)
        XCTAssertEqual(thumbnail?.height, image.height)

        let exportedURL = try await repository.exportFrame(id: frame.id, timestamp: frame.timestamp)
        XCTAssertEqual(exportedURL.deletingLastPathComponent(), exportDirectory)
        XCTAssertEqual(try Data(contentsOf: exportedURL), jpegData)

        guard case .inserted(let inserted) = result.mutation else {
            return XCTFail("Expected an inserted timeline entry")
        }
        XCTAssertEqual(inserted, timeline.first)
        XCTAssertEqual(result.outcome.disposition, .durableFrame)
        XCTAssertTrue(result.outcome.wroteDurableJPEG)
        XCTAssertEqual(result.outcome.metadataWriteByteCounts.count, 1)
        let snapshot = instrumentation.currentSnapshot()
        XCTAssertEqual(snapshot.encodedFrames, 0, "The repository must not claim an encode it did not perform")
        XCTAssertEqual(snapshot.persistedFrames, 0, "FrameBuffer owns repository-outcome metrics")
        XCTAssertEqual(snapshot.logicalJPEGBytesWritten, 0)
    }

    func testDiskRepositoryMemoryPressureIsANoOpAndPreservesDurableHistory() async throws {
        let store = try FrameStore(directory: directory)
        let repository = DiskFrameRepository(frameStore: store)
        let frame = StoredFrame(
            id: UUID(),
            timestamp: Date(),
            hash: 43,
            displayID: nil,
            displayName: nil
        )
        let jpegData = try XCTUnwrap(
            ImageEncoder.jpegData(from: makeImage(width: 8, height: 8), quality: 0.8)
        )
        _ = try await repository.beginCaptureSession(at: frame.timestamp)
        _ = try await repository.recordEncodedCapture(frame, jpegData: jpegData)
        let timelineBefore = await repository.orderedTimeline()
        let statisticsBefore = await repository.storageStatistics()

        let warning = await repository.respondToMemoryPressure(.warning)
        let critical = await repository.respondToMemoryPressure(.critical)
        let timelineAfter = await repository.orderedTimeline()
        let statisticsAfter = await repository.storageStatistics()

        XCTAssertEqual(warning, .noOp)
        XCTAssertEqual(critical, .noOp)
        XCTAssertEqual(timelineAfter, timelineBefore)
        XCTAssertEqual(statisticsAfter, statisticsBefore)
    }

    func testStableIDCollisionNeverOverwritesExistingEncodedPayload() async throws {
        let store = try FrameStore(directory: directory)
        let repository = DiskFrameRepository(frameStore: store)
        let frame = StoredFrame(
            id: UUID(),
            timestamp: Date(),
            hash: 1,
            displayID: nil,
            displayName: nil
        )
        let originalJPEG = try XCTUnwrap(
            ImageEncoder.jpegData(from: makeImage(width: 8, height: 8), quality: 0.8)
        )
        let replacementJPEG = try XCTUnwrap(
            ImageEncoder.jpegData(from: makeImage(width: 16, height: 8), quality: 0.8)
        )
        _ = try await repository.beginCaptureSession(at: frame.timestamp)
        _ = try await repository.recordEncodedCapture(frame, jpegData: originalJPEG)

        do {
            let collidingFrame = StoredFrame(
                id: frame.id,
                timestamp: frame.timestamp.addingTimeInterval(1),
                hash: frame.hash,
                displayID: frame.displayID,
                displayName: frame.displayName
            )
            _ = try await repository.recordEncodedCapture(collidingFrame, jpegData: replacementJPEG)
            XCTFail("Expected a stable-ID collision")
        } catch let FrameStoreError.frameAlreadyExists(id) {
            XCTAssertEqual(id, frame.id)
        }

        let payloadURL = directory
            .appendingPathComponent("frames", isDirectory: true)
            .appendingPathComponent("\(frame.id.uuidString).jpg")
        XCTAssertEqual(try Data(contentsOf: payloadURL), originalJPEG)
        let orderedFrames = await repository.orderedFrames()
        XCTAssertEqual(orderedFrames.map(\.id), [frame.id])
        XCTAssertEqual(orderedFrames.map(\.hash), [frame.hash])
        XCTAssertEqual(
            try XCTUnwrap(orderedFrames.first).timestamp.timeIntervalSince1970,
            frame.timestamp.timeIntervalSince1970,
            accuracy: 0.000_001
        )
    }

    func testDirectFrameStoreSaveStillRecordsItsOwnEncodingAndPersistenceMetrics() async throws {
        let instrumentation = CapturePersistenceInstrumentation()
        let store = try FrameStore(directory: directory, instrumentation: instrumentation)
        let image = try makeImage(width: 12, height: 8)

        let metadata = try await store.saveFrame(
            image,
            timestamp: Date(),
            hash: 7,
            displayID: nil,
            displayName: nil
        )

        let snapshot = instrumentation.currentSnapshot()
        XCTAssertEqual(snapshot.encodedFrames, 1)
        XCTAssertEqual(snapshot.persistedFrames, 1)
        XCTAssertEqual(snapshot.logicalJPEGBytesWritten, metadata.fileSize)
        XCTAssertEqual(snapshot.metadataTransactions, 1)
        XCTAssertEqual(snapshot.durableRepositorySaves, 0)
    }

    func testPromotionPreservesIdentityExactBytesAndAbsoluteSpanMetadata() async throws {
        let store = try FrameStore(directory: directory)
        let repository = DiskFrameRepository(frameStore: store)
        let session = try await repository.beginCaptureSession(
            at: Date(timeIntervalSince1970: 10_000)
        )
        let displayID = UUID()
        let entry = makeEntry(
            sessionID: session.id,
            timestamp: Date(timeIntervalSince1970: 10_001),
            observedThroughAt: Date(timeIntervalSince1970: 10_004),
            observationCount: 4,
            displayID: displayID,
            frameDisplayName: "Frame Display",
            spanDisplayName: "Latest Display"
        )
        let jpegData = Data([0xff, 0xd8, 0x01, 0x02, 0xff, 0xd9])

        let result = try await repository.promoteVolatileEntry(entry, jpegData: jpegData)

        XCTAssertEqual(result.effect, .inserted)
        XCTAssertTrue(result.wroteDurableJPEG)
        XCTAssertGreaterThan(result.logicalMetadataByteCount, 0)
        XCTAssertEqual(result.entry, entry)
        let durable = try await repository.durableEntry(
            frameID: entry.frame.id,
            spanID: entry.span.id
        )
        let persistedPayload = try await repository.encodedPayload(id: entry.frame.id)
        XCTAssertEqual(durable, entry)
        XCTAssertEqual(persistedPayload, jpegData)
        XCTAssertEqual(
            try sqliteInt(
                databaseURL: directory.appendingPathComponent("frames.sqlite"),
                sql: "PRAGMA user_version;"
            ),
            2,
            "Promotion must not require a schema bump"
        )
    }

    func testPromotionRetryIsIdempotentAndCanMonotonicallyReconcile() async throws {
        let store = try FrameStore(directory: directory)
        let repository = DiskFrameRepository(frameStore: store)
        let session = try await repository.beginCaptureSession(at: Date(timeIntervalSince1970: 11_000))
        let entry = makeEntry(
            sessionID: session.id,
            timestamp: Date(timeIntervalSince1970: 11_001),
            observedThroughAt: Date(timeIntervalSince1970: 11_002),
            observationCount: 2
        )
        let jpegData = Data(repeating: 7, count: 32)
        _ = try await repository.promoteVolatileEntry(entry, jpegData: jpegData)

        let retry = try await repository.promoteVolatileEntry(entry, jpegData: jpegData)
        XCTAssertEqual(retry.effect, .noOp)
        XCTAssertFalse(retry.wroteDurableJPEG)
        XCTAssertEqual(retry.logicalMetadataByteCount, 0)

        let advanced = replacingSpan(
            in: entry,
            observedThroughAt: Date(timeIntervalSince1970: 11_005),
            observationCount: 5
        )
        let reconciliation = try await repository.promoteVolatileEntry(
            advanced,
            jpegData: jpegData
        )
        XCTAssertEqual(reconciliation.effect, .checkpointed)
        XCTAssertFalse(reconciliation.wroteDurableJPEG)
        XCTAssertGreaterThan(reconciliation.logicalMetadataByteCount, 0)

        let olderRetry = try await repository.promoteVolatileEntry(entry, jpegData: jpegData)
        XCTAssertEqual(olderRetry.effect, .noOp)
        XCTAssertEqual(olderRetry.entry, advanced)
        let timeline = await repository.orderedTimeline()
        let persistedPayload = try await repository.encodedPayload(id: entry.frame.id)
        XCTAssertEqual(timeline.count, 1)
        XCTAssertEqual(persistedPayload, jpegData)
    }

    func testPromotionConflictsFailWithoutOverwritingDurableIdentity() async throws {
        let store = try FrameStore(directory: directory)
        let repository = DiskFrameRepository(frameStore: store)
        let session = try await repository.beginCaptureSession(at: Date(timeIntervalSince1970: 12_000))
        let entry = makeEntry(
            sessionID: session.id,
            timestamp: Date(timeIntervalSince1970: 12_001)
        )
        let jpegData = Data(repeating: 3, count: 24)
        _ = try await repository.promoteVolatileEntry(entry, jpegData: jpegData)

        do {
            _ = try await repository.promoteVolatileEntry(
                entry,
                jpegData: Data(repeating: 4, count: jpegData.count)
            )
            XCTFail("Expected conflicting bytes to fail")
        } catch FrameStoreError.promotionConflict {
        }

        let collidingSpan = TimelineEntry(
            span: TimelineSpan(
                id: UUID(),
                frameID: entry.frame.id,
                sessionID: session.id,
                startedAt: entry.span.startedAt,
                observedThroughAt: entry.span.observedThroughAt,
                observationCount: entry.span.observationCount,
                displayID: entry.span.displayID,
                displayName: entry.span.displayName
            ),
            frame: entry.frame
        )
        do {
            _ = try await repository.promoteVolatileEntry(collidingSpan, jpegData: jpegData)
            XCTFail("Expected a frame-ID collision with a different span ID")
        } catch FrameStoreError.promotionConflict {
        }

        let timeline = await repository.orderedTimeline()
        let persistedPayload = try await repository.encodedPayload(id: entry.frame.id)
        XCTAssertEqual(timeline, [entry])
        XCTAssertEqual(persistedPayload, jpegData)
    }

    func testPromotionRejectsMissingWrongAndClosedSessionsBeforeWritingPayload() async throws {
        let store = try FrameStore(directory: directory)
        let repository = DiskFrameRepository(frameStore: store)
        let base = Date(timeIntervalSince1970: 13_000)
        let missing = makeEntry(sessionID: UUID(), timestamp: base)
        await assertPromotionRejected(missing, repository: repository)

        let session = try await repository.beginCaptureSession(at: base)
        let wrong = makeEntry(
            sessionID: UUID(),
            timestamp: base.addingTimeInterval(1)
        )
        await assertPromotionRejected(wrong, repository: repository)

        _ = try await repository.endCaptureSession(id: session.id, reason: .paused)
        let closed = makeEntry(
            sessionID: session.id,
            timestamp: base.addingTimeInterval(2)
        )
        await assertPromotionRejected(closed, repository: repository)
        let timeline = await repository.orderedTimeline()
        XCTAssertTrue(timeline.isEmpty)
    }

    func testPromotionRejectsInvalidIdentityBoundsAndObservationCount() async throws {
        let store = try FrameStore(directory: directory)
        let repository = DiskFrameRepository(frameStore: store)
        let session = try await repository.beginCaptureSession(at: Date(timeIntervalSince1970: 13_500))
        let valid = makeEntry(
            sessionID: session.id,
            timestamp: Date(timeIntervalSince1970: 13_501)
        )
        let wrongFrame = TimelineEntry(
            span: TimelineSpan(
                id: valid.span.id,
                frameID: UUID(),
                sessionID: valid.span.sessionID,
                startedAt: valid.span.startedAt,
                observedThroughAt: valid.span.observedThroughAt,
                observationCount: valid.span.observationCount,
                displayID: valid.span.displayID,
                displayName: valid.span.displayName
            ),
            frame: valid.frame
        )
        let reversedBounds = TimelineEntry(
            span: TimelineSpan(
                id: valid.span.id,
                frameID: valid.span.frameID,
                sessionID: valid.span.sessionID,
                startedAt: valid.span.startedAt,
                observedThroughAt: valid.span.startedAt.addingTimeInterval(-1),
                observationCount: valid.span.observationCount,
                displayID: valid.span.displayID,
                displayName: valid.span.displayName
            ),
            frame: valid.frame
        )
        let zeroCount = TimelineEntry(
            span: TimelineSpan(
                id: valid.span.id,
                frameID: valid.span.frameID,
                sessionID: valid.span.sessionID,
                startedAt: valid.span.startedAt,
                observedThroughAt: valid.span.observedThroughAt,
                observationCount: 0,
                displayID: valid.span.displayID,
                displayName: valid.span.displayName
            ),
            frame: valid.frame
        )

        for invalid in [wrongFrame, reversedBounds, zeroCount] {
            await assertPromotionRejected(invalid, repository: repository)
        }
    }

    func testCheckpointUsesAbsoluteMonotonicMergeAndRejectsImmutableConflicts() async throws {
        let store = try FrameStore(directory: directory)
        let repository = DiskFrameRepository(frameStore: store)
        let session = try await repository.beginCaptureSession(at: Date(timeIntervalSince1970: 14_000))
        let entry = makeEntry(
            sessionID: session.id,
            timestamp: Date(timeIntervalSince1970: 14_001),
            observedThroughAt: Date(timeIntervalSince1970: 14_002),
            observationCount: 2,
            displayID: UUID(),
            frameDisplayName: "Display",
            spanDisplayName: "Display"
        )
        _ = try await repository.promoteVolatileEntry(entry, jpegData: Data(repeating: 5, count: 20))

        let advanced = replacingSpan(
            in: entry,
            observedThroughAt: Date(timeIntervalSince1970: 14_006),
            observationCount: 6
        ).span
        let checkpoint = try await repository.checkpointPromotedSpan(advanced)
        XCTAssertEqual(checkpoint.effect, .checkpointed)
        XCTAssertFalse(checkpoint.wroteDurableJPEG)
        XCTAssertGreaterThan(checkpoint.logicalMetadataByteCount, 0)

        let equal = try await repository.checkpointPromotedSpan(advanced)
        XCTAssertEqual(equal.effect, .noOp)
        XCTAssertEqual(equal.logicalMetadataByteCount, 0)

        let older = replacingSpan(
            in: entry,
            observedThroughAt: Date(timeIntervalSince1970: 14_004),
            observationCount: 4
        ).span
        let olderResult = try await repository.checkpointPromotedSpan(older)
        XCTAssertEqual(olderResult.effect, .noOp)
        XCTAssertEqual(olderResult.entry.span, advanced)

        let crossed = replacingSpan(
            in: entry,
            observedThroughAt: Date(timeIntervalSince1970: 14_007),
            observationCount: 5
        ).span
        await assertCheckpointRejected(crossed, repository: repository)

        let wrongFrame = TimelineSpan(
            id: advanced.id,
            frameID: UUID(),
            sessionID: advanced.sessionID,
            startedAt: advanced.startedAt,
            observedThroughAt: advanced.observedThroughAt,
            observationCount: advanced.observationCount,
            displayID: advanced.displayID,
            displayName: advanced.displayName
        )
        await assertCheckpointRejected(wrongFrame, repository: repository)

        let wrongDisplay = TimelineSpan(
            id: advanced.id,
            frameID: advanced.frameID,
            sessionID: advanced.sessionID,
            startedAt: advanced.startedAt,
            observedThroughAt: advanced.observedThroughAt,
            observationCount: advanced.observationCount,
            displayID: UUID(),
            displayName: advanced.displayName
        )
        await assertCheckpointRejected(wrongDisplay, repository: repository)

        let wrongSession = TimelineSpan(
            id: advanced.id,
            frameID: advanced.frameID,
            sessionID: UUID(),
            startedAt: advanced.startedAt,
            observedThroughAt: advanced.observedThroughAt,
            observationCount: advanced.observationCount,
            displayID: advanced.displayID,
            displayName: advanced.displayName
        )
        await assertCheckpointRejected(wrongSession, repository: repository)
    }

    func testPromotionAndCheckpointMergeLatestNonNilSpanDisplayName() async throws {
        let store = try FrameStore(directory: directory)
        let repository = DiskFrameRepository(frameStore: store)
        let session = try await repository.beginCaptureSession(at: Date(timeIntervalSince1970: 14_500))
        let entry = makeEntry(
            sessionID: session.id,
            timestamp: Date(timeIntervalSince1970: 14_501),
            observedThroughAt: Date(timeIntervalSince1970: 14_502),
            observationCount: 2,
            displayID: UUID(),
            frameDisplayName: "Captured Display",
            spanDisplayName: "Original Name"
        )
        let jpegData = Data(repeating: 25, count: 20)
        _ = try await repository.promoteVolatileEntry(entry, jpegData: jpegData)

        let equalRename = replacingSpanDisplayName(in: entry, with: "Equal Rename")
        let equalRenameResult = try await repository.promoteVolatileEntry(
            equalRename,
            jpegData: jpegData
        )
        XCTAssertEqual(equalRenameResult.effect, .noOp)
        XCTAssertEqual(equalRenameResult.entry.span.displayName, "Original Name")
        XCTAssertEqual(equalRenameResult.logicalMetadataByteCount, 0)

        let advancingPromotion = replacingSpanDisplayName(
            in: replacingSpan(
                in: entry,
                observedThroughAt: Date(timeIntervalSince1970: 14_506),
                observationCount: 6
            ),
            with: "Latest Display"
        )
        let promotedRename = try await repository.promoteVolatileEntry(
            advancingPromotion,
            jpegData: jpegData
        )
        XCTAssertEqual(promotedRename.effect, .checkpointed)
        XCTAssertEqual(promotedRename.entry.span.displayName, "Latest Display")
        XCTAssertFalse(promotedRename.wroteDurableJPEG)
        XCTAssertGreaterThan(promotedRename.logicalMetadataByteCount, 0)

        let equalOldName = replacingSpanDisplayName(
            in: advancingPromotion,
            with: "Original Name"
        )
        let equalOldNameRetry = try await repository.checkpointPromotedSpan(equalOldName.span)
        XCTAssertEqual(equalOldNameRetry.effect, .noOp)
        XCTAssertEqual(equalOldNameRetry.entry.span.displayName, "Latest Display")

        let advanced = replacingSpan(
            in: advancingPromotion,
            observedThroughAt: Date(timeIntervalSince1970: 14_506),
            observationCount: 7
        )
        let checkpointRename = replacingSpanDisplayName(in: advanced, with: "Latest Checkpoint Name")
        let checkpoint = try await repository.checkpointPromotedSpan(checkpointRename.span)
        XCTAssertEqual(checkpoint.effect, .checkpointed)
        XCTAssertEqual(checkpoint.entry.span.displayName, "Latest Checkpoint Name")

        let staleRename = replacingSpanDisplayName(in: entry, with: "Stale Display")
        let stale = try await repository.checkpointPromotedSpan(staleRename.span)
        XCTAssertEqual(stale.effect, .noOp)
        XCTAssertEqual(stale.entry.span.displayName, "Latest Checkpoint Name")

        let nilNameAdvance = replacingSpanDisplayName(
            in: replacingSpan(
                in: checkpointRename,
                observedThroughAt: Date(timeIntervalSince1970: 14_508),
                observationCount: 8
            ),
            with: nil
        )
        let nilCheckpoint = try await repository.checkpointPromotedSpan(nilNameAdvance.span)
        XCTAssertEqual(nilCheckpoint.effect, .checkpointed)
        XCTAssertEqual(nilCheckpoint.entry.span.displayName, "Latest Checkpoint Name")
    }

    func testPromotionRetriesAfterPostPayloadPreDatabaseFailureWithoutPhantomTimeline() async throws {
        let instrumentation = CapturePersistenceInstrumentation()
        let store = try FrameStore(
            directory: directory,
            promotionPayloadDidWrite: { _ in throw DurablePersistenceTestError.injected }
        )
        let repository = DiskFrameRepository(frameStore: store)
        let session = try await repository.beginCaptureSession(at: Date(timeIntervalSince1970: 15_000))
        let entry = makeEntry(
            sessionID: session.id,
            timestamp: Date(timeIntervalSince1970: 15_001),
            displayID: UUID()
        )
        let jpegData = Data(repeating: 6, count: 18)
        var writeReceipts: [DurableJPEGWriteReceipt] = []

        do {
            _ = try await repository.promoteVolatileEntry(entry, jpegData: jpegData)
            XCTFail("Expected the injected post-payload failure")
        } catch let failure as DurablePromotionFailure {
            writeReceipts.append(failure.writeReceipt)
            instrumentation.recordPersistedJPEG(receipt: failure.writeReceipt)
            XCTAssertFalse(failure.underlyingDescription.isEmpty)
        } catch {
            XCTFail("Unexpected promotion error: \(error)")
        }
        XCTAssertEqual(writeReceipts.count, 1)
        XCTAssertEqual(writeReceipts[0].frameID, entry.frame.id)
        XCTAssertEqual(writeReceipts[0].jpegData, jpegData)
        XCTAssertEqual(writeReceipts[0].byteCount, jpegData.count)
        XCTAssertEqual(writeReceipts[0].displayID, entry.frame.displayID)
        let durable = try await repository.durableEntry(
            frameID: entry.frame.id,
            spanID: entry.span.id
        )
        let emptyTimeline = await repository.orderedTimeline()
        XCTAssertNil(durable)
        XCTAssertTrue(emptyTimeline.isEmpty)
        XCTAssertEqual(try Data(contentsOf: payloadURL(for: entry.frame.id)), jpegData)

        let retry = try await repository.promoteVolatileEntry(entry, jpegData: jpegData)
        XCTAssertEqual(retry.effect, .inserted)
        XCTAssertFalse(retry.wroteDurableJPEG, "Retry must reuse the exact owned orphan")
        XCTAssertGreaterThan(retry.logicalMetadataByteCount, 0)
        XCTAssertEqual(retry.entry, entry)
        instrumentation.recordMetadataWrite(byteCount: retry.logicalMetadataByteCount)
        let instrumentationSnapshot = instrumentation.currentSnapshot()
        XCTAssertEqual(instrumentationSnapshot.persistedFrames, 1)
        XCTAssertEqual(instrumentationSnapshot.logicalJPEGBytesWritten, Int64(jpegData.count))
        XCTAssertEqual(instrumentationSnapshot.metadataTransactions, 1)
        let timeline = await repository.orderedTimeline()
        XCTAssertEqual(timeline, [entry])
    }

    func testStartupCleanupRecoversPostPayloadPreDatabaseOrphan() async throws {
        let entry: TimelineEntry
        do {
            let store = try FrameStore(
                directory: directory,
                promotionPayloadDidWrite: { _ in throw DurablePersistenceTestError.injected }
            )
            let repository = DiskFrameRepository(frameStore: store)
            let session = try await repository.beginCaptureSession(
                at: Date(timeIntervalSince1970: 16_000)
            )
            entry = makeEntry(
                sessionID: session.id,
                timestamp: Date(timeIntervalSince1970: 16_001)
            )
            do {
                _ = try await repository.promoteVolatileEntry(
                    entry,
                    jpegData: Data(repeating: 8, count: 19)
                )
                XCTFail("Expected the injected post-payload failure")
            } catch is DurablePromotionFailure {
            }
        }

        let reopened = try FrameStore(directory: directory)
        try await reopened.cleanupOrphans()

        let timeline = await reopened.getTimelineEntries()
        XCTAssertTrue(timeline.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: payloadURL(for: entry.frame.id).path))
        XCTAssertTrue(recoveryContains(filename: "\(entry.frame.id.uuidString).jpg"))
    }

    func testPromotionDatabaseTransactionFailureRollsBackRowsAndCanRetry() async throws {
        let store = try FrameStore(directory: directory)
        let repository = DiskFrameRepository(frameStore: store)
        let session = try await repository.beginCaptureSession(at: Date(timeIntervalSince1970: 17_000))
        let entry = makeEntry(
            sessionID: session.id,
            timestamp: Date(timeIntervalSince1970: 17_001)
        )
        let jpegData = Data(repeating: 9, count: 21)
        let databaseURL = directory.appendingPathComponent("frames.sqlite")
        try executeSQLite(
            databaseURL: databaseURL,
            sql:
                "CREATE TRIGGER fail_promoted_span BEFORE INSERT ON frame_spans "
                    + "BEGIN SELECT RAISE(ABORT, 'injected promotion failure'); END;"
        )

        do {
            _ = try await repository.promoteVolatileEntry(entry, jpegData: jpegData)
            XCTFail("Expected the injected database transaction failure")
        } catch let failure as DurablePromotionFailure {
            XCTAssertEqual(failure.writeReceipt.frameID, entry.frame.id)
            XCTAssertEqual(failure.writeReceipt.jpegData, jpegData)
            XCTAssertEqual(failure.writeReceipt.displayID, entry.frame.displayID)
        }
        let durable = try await repository.durableEntry(
            frameID: entry.frame.id,
            spanID: entry.span.id
        )
        XCTAssertNil(durable)
        XCTAssertEqual(try sqliteInt(databaseURL: databaseURL, sql: "SELECT COUNT(*) FROM frames;"), 0)
        XCTAssertEqual(try sqliteInt(databaseURL: databaseURL, sql: "SELECT COUNT(*) FROM frame_spans;"), 0)
        XCTAssertEqual(try Data(contentsOf: payloadURL(for: entry.frame.id)), jpegData)

        try executeSQLite(databaseURL: databaseURL, sql: "DROP TRIGGER fail_promoted_span;")
        let retry = try await repository.promoteVolatileEntry(entry, jpegData: jpegData)
        XCTAssertEqual(retry.effect, .inserted)
        XCTAssertFalse(retry.wroteDurableJPEG)
    }

    func testPostCommitPromotionAndCheckpointErrorsReturnReconciledCommittedOnce() async throws {
        let store = try FrameStore(
            directory: directory,
            durableCommitHook: { _ in throw DurablePersistenceTestError.injected }
        )
        let repository = DiskFrameRepository(frameStore: store)
        let session = try await repository.beginCaptureSession(at: Date(timeIntervalSince1970: 18_000))
        let entry = makeEntry(
            sessionID: session.id,
            timestamp: Date(timeIntervalSince1970: 18_001),
            frameDisplayName: "Captured Display",
            spanDisplayName: "Original Name"
        )
        let jpegData = Data(repeating: 10, count: 22)

        let promoted = try await repository.promoteVolatileEntry(entry, jpegData: jpegData)
        XCTAssertEqual(promoted.effect, .reconciledCommitted)
        XCTAssertTrue(promoted.wroteDurableJPEG)
        XCTAssertGreaterThan(promoted.logicalMetadataByteCount, 0)
        let promotionRetry = try await repository.promoteVolatileEntry(entry, jpegData: jpegData)
        XCTAssertEqual(promotionRetry.effect, .noOp)
        XCTAssertFalse(promotionRetry.wroteDurableJPEG)
        XCTAssertEqual(promotionRetry.logicalMetadataByteCount, 0)

        let renamed = replacingSpanDisplayName(
            in: replacingSpan(
                in: entry,
                observedThroughAt: Date(timeIntervalSince1970: 18_004),
                observationCount: 4
            ),
            with: "Renamed Display"
        ).span
        let checkpoint = try await repository.checkpointPromotedSpan(renamed)
        XCTAssertEqual(checkpoint.effect, .reconciledCommitted)
        XCTAssertFalse(checkpoint.wroteDurableJPEG)
        XCTAssertGreaterThan(checkpoint.logicalMetadataByteCount, 0)
        XCTAssertEqual(checkpoint.entry.span.displayName, "Renamed Display")
        let equalOldName = TimelineSpan(
            id: renamed.id,
            frameID: renamed.frameID,
            sessionID: renamed.sessionID,
            startedAt: renamed.startedAt,
            observedThroughAt: renamed.observedThroughAt,
            observationCount: renamed.observationCount,
            displayID: renamed.displayID,
            displayName: "Original Name"
        )
        let checkpointRetry = try await repository.checkpointPromotedSpan(equalOldName)
        XCTAssertEqual(checkpointRetry.effect, .noOp)
        XCTAssertEqual(checkpointRetry.logicalMetadataByteCount, 0)
        XCTAssertEqual(checkpointRetry.entry.span, renamed)
    }

    func testPromotedEntrySurvivesRestartWithExactPayloadAndTimeline() async throws {
        let entry: TimelineEntry
        let jpegData = Data(repeating: 11, count: 23)
        do {
            let store = try FrameStore(directory: directory)
            let repository = DiskFrameRepository(frameStore: store)
            let session = try await repository.beginCaptureSession(
                at: Date(timeIntervalSince1970: 19_000)
            )
            entry = makeEntry(
                sessionID: session.id,
                timestamp: Date(timeIntervalSince1970: 19_001),
                observedThroughAt: Date(timeIntervalSince1970: 19_003),
                observationCount: 3
            )
            _ = try await repository.promoteVolatileEntry(entry, jpegData: jpegData)
            _ = try await repository.endCaptureSession(id: session.id, reason: .paused)
            await repository.flush()
        }

        let reopenedStore = try FrameStore(directory: directory)
        let reopened = DiskFrameRepository(frameStore: reopenedStore)
        let timeline = await reopened.orderedTimeline()
        let durable = try await reopened.durableEntry(
            frameID: entry.frame.id,
            spanID: entry.span.id
        )
        let persistedPayload = try await reopened.encodedPayload(id: entry.frame.id)
        XCTAssertEqual(timeline, [entry])
        XCTAssertEqual(durable, entry)
        XCTAssertEqual(persistedPayload, jpegData)
    }

    private func assertPromotionRejected(
        _ entry: TimelineEntry,
        repository: DiskFrameRepository
    ) async {
        do {
            _ = try await repository.promoteVolatileEntry(
                entry,
                jpegData: Data(repeating: 1, count: 12)
            )
            XCTFail("Expected promotion to be rejected")
        } catch FrameStoreError.promotionConflict {
        } catch {
            XCTFail("Unexpected promotion error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: payloadURL(for: entry.frame.id).path))
    }

    private func assertCheckpointRejected(
        _ span: TimelineSpan,
        repository: DiskFrameRepository
    ) async {
        do {
            _ = try await repository.checkpointPromotedSpan(span)
            XCTFail("Expected checkpoint to be rejected")
        } catch FrameStoreError.promotionConflict {
        } catch {
            XCTFail("Unexpected checkpoint error: \(error)")
        }
    }

    private func makeEntry(
        sessionID: UUID,
        timestamp: Date,
        observedThroughAt: Date? = nil,
        observationCount: Int = 1,
        displayID: UUID? = nil,
        frameDisplayName: String? = nil,
        spanDisplayName: String? = nil
    ) -> TimelineEntry {
        let frame = StoredFrame(
            id: UUID(),
            timestamp: timestamp,
            hash: 0x1234_5678,
            displayID: displayID,
            displayName: frameDisplayName
        )
        return TimelineEntry(
            span: TimelineSpan(
                id: UUID(),
                frameID: frame.id,
                sessionID: sessionID,
                startedAt: timestamp,
                observedThroughAt: observedThroughAt ?? timestamp,
                observationCount: observationCount,
                displayID: displayID,
                displayName: spanDisplayName ?? frameDisplayName
            ),
            frame: frame
        )
    }

    private func replacingSpan(
        in entry: TimelineEntry,
        observedThroughAt: Date,
        observationCount: Int
    ) -> TimelineEntry {
        TimelineEntry(
            span: TimelineSpan(
                id: entry.span.id,
                frameID: entry.span.frameID,
                sessionID: entry.span.sessionID,
                startedAt: entry.span.startedAt,
                observedThroughAt: observedThroughAt,
                observationCount: observationCount,
                displayID: entry.span.displayID,
                displayName: entry.span.displayName
            ),
            frame: entry.frame
        )
    }

    private func replacingSpanDisplayName(
        in entry: TimelineEntry,
        with displayName: String?
    ) -> TimelineEntry {
        TimelineEntry(
            span: TimelineSpan(
                id: entry.span.id,
                frameID: entry.span.frameID,
                sessionID: entry.span.sessionID,
                startedAt: entry.span.startedAt,
                observedThroughAt: entry.span.observedThroughAt,
                observationCount: entry.span.observationCount,
                displayID: entry.span.displayID,
                displayName: displayName
            ),
            frame: entry.frame
        )
    }

    private func payloadURL(for id: UUID) -> URL {
        directory
            .appendingPathComponent("frames", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).jpg")
    }

    private func recoveryContains(filename: String) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: FrameStore.recoveryDirectory(in: directory),
            includingPropertiesForKeys: nil
        ) else { return false }
        return enumerator.compactMap { ($0 as? URL)?.lastPathComponent }.contains(filename)
    }

    private func sqliteInt(databaseURL: URL, sql: String) throws -> Int {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let connection else {
            throw FrameDatabaseError.sqlite("Failed to inspect promotion test database")
        }
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw FrameDatabaseError.sqlite("Failed to prepare promotion test query")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw FrameDatabaseError.sqlite("Promotion test query returned no row")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func executeSQLite(databaseURL: URL, sql: String) throws {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &connection,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE,
            nil
        ) == SQLITE_OK,
        let connection else {
            throw FrameDatabaseError.sqlite("Failed to open promotion test database")
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 5_000)
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw FrameDatabaseError.sqlite("Failed to mutate promotion test database")
        }
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        try XCTUnwrap(
            TestImageFactory.makeImage(width: width, height: height) { x, y in
                (
                    UInt8((x * 29 + y * 7) % 256),
                    UInt8((x * 11 + y * 31) % 256),
                    UInt8((x * 3 + y * 17) % 256)
                )
            }
        )
    }
}

private enum DurablePersistenceTestError: Error {
    case injected
}
