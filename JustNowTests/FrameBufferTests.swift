import CoreGraphics
import Foundation
import SQLite3
import XCTest
@testable import JustNow

private enum FrameRepositoryProbeError: Error {
    case beginFailed
    case clearFailed
    case endFailed
    case sessionMismatch
}

@MainActor
final class FrameBufferTests: XCTestCase {
    private final class InMemoryCaptureMetricsLog: CaptureInstrumentationLogSink {
        private(set) var entries: [(category: String, message: String)] = []

        func log(_ category: String, _ message: String) {
            entries.append((category, message))
        }
    }

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameBufferTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func makeBuffer(
        diagnosticsLog: CaptureInstrumentationLogSink? = nil
    ) async throws -> FrameBuffer {
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: diagnosticsLog,
            historyStorageMode: .allDisk
        )
        try await buffer.beginCaptureSession(at: Date(timeIntervalSince1970: 0))
        return buffer
    }

    func testStandardDuplicatePolicyMatchesDefaultCaptureInterval() {
        XCTAssertEqual(
            DuplicateFramePolicy.standard,
            .exact(atMostEvery: AppStorageDefault.captureInterval)
        )
    }

    func testEffectiveHistoryModeIsImmutableForBufferLifetime() async throws {
        let mode = HistoryStorageMode.hybridRAM(
            byteCap: RecentDetailMemoryLimit.mb256.byteCount
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            historyStorageMode: mode
        )

        XCTAssertEqual(buffer.historyStorageMode, mode)
        XCTAssertNotEqual(
            buffer.historyStorageMode,
            .hybridRAM(byteCap: RecentDetailMemoryLimit.mb1024.byteCount)
        )
    }

    func testPressureWaitsForAdmittedIngestBeforeMaintenanceReconciliation() async throws {
        let image = try makeStructuredImage(seed: 900)
        let repository = FrameRepositoryProbe(
            frames: [],
            image: image,
            exportedURL: directory.appendingPathComponent("export.jpg"),
            suspendFirstSave: true
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository,
            historyStorageMode: .hybridRAM(byteCap: 64),
            jpegEncoder: FrameJPEGEncoder { _, _ in Data(repeating: 7, count: 16) }
        )
        try await buffer.beginCaptureSession(at: Date(timeIntervalSince1970: 0))
        buffer.addFrame(image, timestamp: Date(), display: nil)
        await repository.waitForSaveInvocation(count: 1)

        var pressureFinished = false
        let pressure = Task { @MainActor in
            _ = await buffer.respondToMemoryPressure(.critical)
            pressureFinished = true
        }
        await Task.yield()
        XCTAssertFalse(pressureFinished)

        await repository.resumeSuspendedSave()
        await pressure.value
        XCTAssertTrue(pressureFinished)
        XCTAssertEqual(buffer.getTimelineEntries().count, 1)
    }

    func testCriticalPressureClearsDecodedCacheWithoutFlushingOrWritingTextCache() async throws {
        let image = try makeStructuredImage(seed: 901)
        let frame = StoredFrame(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1),
            hash: 1,
            displayID: nil,
            displayName: nil
        )
        let repository = FrameRepositoryProbe(
            frames: [frame],
            image: image,
            exportedURL: directory.appendingPathComponent("export.jpg")
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository
        )
        let baselineTextWrites = await buffer.textCache.mutationTransactionCountForTesting()

        _ = try await buffer.getFullImage(for: frame)
        _ = try await buffer.getFullImage(for: frame)
        let initialFullImageRequests = await repository.fullImageRequests()
        XCTAssertEqual(initialFullImageRequests.count, 1)

        _ = await buffer.respondToMemoryPressure(.critical)
        _ = try await buffer.getFullImage(for: frame)

        let finalTextWrites = await buffer.textCache.mutationTransactionCountForTesting()
        let fullImageRequests = await repository.fullImageRequests()
        let flushInvocations = await repository.flushInvocationCount()
        XCTAssertEqual(fullImageRequests.count, 2)
        XCTAssertEqual(flushInvocations, 0)
        XCTAssertEqual(finalTextWrites, baselineTextWrites)
    }

    func testCriticalPressurePreventsSuspendedDecodeFromRepopulatingCache() async throws {
        let image = try makeStructuredImage(seed: 905)
        let frame = StoredFrame(
            id: UUID(),
            timestamp: Date(),
            hash: 905,
            displayID: nil,
            displayName: nil
        )
        let repository = FrameRepositoryProbe(
            frames: [frame],
            image: image,
            exportedURL: directory.appendingPathComponent("export.jpg"),
            suspendFirstFullImage: true
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository
        )

        let firstLoad = Task { @MainActor in
            try? await buffer.getFullImage(for: frame)
        }
        await repository.waitForFullImageInvocation()
        _ = await buffer.respondToMemoryPressure(.critical)
        await repository.resumeSuspendedFullImage()
        _ = await firstLoad.value
        _ = try await buffer.getFullImage(for: frame)

        let requests = await repository.fullImageRequests()
        XCTAssertEqual(requests, [frame.id, frame.id])
    }

    func testSuspendedPressureEffectsReturningAfterSuccessfulClearAreDiscarded() async throws {
        let image = try makeStructuredImage(seed: 902)
        let staleEntry = makeTimelineEntry(at: Date(), hash: 902)
        let maintenance = FrameRepositoryMaintenanceResult(
            effects: FrameRepositoryEffects(
                timelineUpserts: [staleEntry],
                invalidation: .none,
                newlyDurableEntries: [],
                persistenceEvents: []
            ),
            bytesBefore: 16,
            bytesAfter: 0,
            targetBytes: 0
        )
        let repository = FrameRepositoryProbe(
            frames: [],
            image: image,
            exportedURL: directory.appendingPathComponent("export.jpg"),
            suspendFirstPressure: true,
            pressureResult: maintenance
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository
        )
        try await buffer.beginCaptureSession()

        let pressure = Task { @MainActor in
            await buffer.respondToMemoryPressure(.critical)
        }
        await repository.waitForPressureInvocation()
        try await buffer.clear()
        await repository.resumeSuspendedPressure()
        _ = await pressure.value

        XCTAssertTrue(buffer.getTimelineEntries().isEmpty)
        XCTAssertFalse(buffer.containsFrame(id: staleEntry.frame.id))
    }

    func testFailedClearDoesNotFenceSuspendedPressureEffects() async throws {
        let image = try makeStructuredImage(seed: 903)
        let recoveredEntry = makeTimelineEntry(at: Date(), hash: 903)
        let maintenance = FrameRepositoryMaintenanceResult(
            effects: FrameRepositoryEffects(
                timelineUpserts: [recoveredEntry],
                invalidation: .none,
                newlyDurableEntries: [],
                persistenceEvents: []
            ),
            bytesBefore: 16,
            bytesAfter: 0,
            targetBytes: 0
        )
        let repository = FrameRepositoryProbe(
            frames: [],
            image: image,
            exportedURL: directory.appendingPathComponent("export.jpg"),
            suspendFirstPressure: true,
            clearFailures: 1,
            pressureResult: maintenance
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository
        )
        try await buffer.beginCaptureSession()

        let pressure = Task { @MainActor in
            await buffer.respondToMemoryPressure(.warning)
        }
        await repository.waitForPressureInvocation()
        do {
            try await buffer.clear()
            XCTFail("Expected the injected pre-commit clear failure")
        } catch FrameRepositoryProbeError.clearFailed {
            // The repository did not commit the reset, so the old epoch lives.
        }
        await repository.resumeSuspendedPressure()
        _ = await pressure.value

        XCTAssertEqual(buffer.getTimelineEntries(), [recoveredEntry])
    }

    func testSuspendedLeaseMaintenanceReturningAfterClearCannotRestoreFallback() async throws {
        let image = try makeStructuredImage(seed: 904)
        let staleEntry = makeTimelineEntry(at: Date(), hash: 904)
        let maintenance = FrameRepositoryMaintenanceResult(
            effects: FrameRepositoryEffects(
                timelineUpserts: [staleEntry],
                invalidation: .none,
                newlyDurableEntries: [],
                persistenceEvents: []
            ),
            bytesBefore: 16,
            bytesAfter: 0,
            targetBytes: 0
        )
        let lease = BlockingMaintenancePayloadLease(result: maintenance)
        let repository = FrameRepositoryProbe(
            frames: [],
            image: image,
            exportedURL: directory.appendingPathComponent("export.jpg")
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository
        )
        try await buffer.beginCaptureSession()

        let release = Task { @MainActor in
            await buffer.releasePayloadLease(lease)
        }
        await lease.waitUntilReleaseRequested()
        try await buffer.clear()
        await lease.permitRelease()
        _ = await release.value

        XCTAssertTrue(buffer.getTimelineEntries().isEmpty)
        XCTAssertFalse(buffer.containsFrame(id: staleEntry.frame.id))
    }

    func testHybridAdmissionEvaluatesEveryCaptureBeforeCadenceFiltering() async throws {
        let image = try makeStructuredImage(seed: 701)
        let store = try FrameStore(directory: directory)
        let repository = HybridFrameRepository(frameStore: store, byteCap: 64)
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository,
            historyStorageMode: .hybridRAM(byteCap: 64),
            jpegEncoder: FrameJPEGEncoder { _, _ in Data(repeating: 7, count: 16) }
        )
        let base = Date()
        try await buffer.beginCaptureSession(at: base)

        await buffer.addFrameSync(image, timestamp: base, display: nil)
        await buffer.addFrameSync(image, timestamp: base.addingTimeInterval(0.01), display: nil)

        let entries = buffer.getTimelineEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.span.observationCount, 2)
        let metrics = buffer.captureInstrumentationSnapshot()
        XCTAssertEqual(metrics.encodedFrames, 2)
        XCTAssertEqual(metrics.durableRepositorySaves, 1)
        XCTAssertEqual(metrics.firstAnchorRepositorySaves, 1)
        XCTAssertEqual(metrics.volatileRepositorySaves, 0)
        XCTAssertEqual(metrics.duplicateRepositorySaves, 1)
        let statistics = await buffer.storageStatistics()
        XCTAssertGreaterThan(statistics.durableJPEGPayloadBytes, 0)
        XCTAssertEqual(statistics.volatileObservationCount, 2)
    }

    func testHybridExactDuplicatesAvoidDurableAndTextCacheWritesBetweenAnchors() async throws {
        let firstImage = try makeStructuredImage(seed: 702)
        let secondImage = firstImage
        let firstJPEG = try XCTUnwrap(ImageEncoder.jpegData(from: firstImage, quality: 0.8))
        let secondJPEG = try XCTUnwrap(ImageEncoder.jpegData(from: secondImage, quality: 0.6))
        let encoder = SequencedJPEGEncoderProbe(data: [firstJPEG, secondJPEG, secondJPEG])
        let store = try FrameStore(directory: directory)
        let durable = HybridDurableRepositoryProbe(
            base: DiskFrameRepository(frameStore: store)
        )
        let repository = HybridFrameRepository(
            durableRepository: durable,
            byteCap: max(firstJPEG.count, secondJPEG.count)
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository,
            historyStorageMode: .hybridRAM(byteCap: max(firstJPEG.count, secondJPEG.count)),
            jpegEncoder: FrameJPEGEncoder { image, quality in
                encoder.encode(image: image, quality: quality)
            }
        )
        let base = Date()
        try await buffer.beginCaptureSession(at: base)
        let baselineTextTransactions = await buffer.textCache.mutationTransactionCountForTesting()
        let baselineDatabaseFiles = try sqliteFileNames(in: directory, baseName: "frames.sqlite")
        await durable.resetMutationCallCounts()

        // The second distinct payload evicts the first under this one-payload
        // cap; the third capture exactly extends the second in RAM.
        await buffer.addFrameSync(firstImage, timestamp: base, display: nil)
        await buffer.addFrameSync(secondImage, timestamp: base.addingTimeInterval(0.5), display: nil)
        await buffer.addFrameSync(secondImage, timestamp: base.addingTimeInterval(0.75), display: nil)

        let snapshot = buffer.captureInstrumentationSnapshot()
        XCTAssertEqual(snapshot.encodedFrames, 3)
        XCTAssertEqual(snapshot.persistedFrames, 1)
        XCTAssertEqual(snapshot.logicalDurableJPEGEventBytes, Int64(firstJPEG.count))
        XCTAssertGreaterThan(snapshot.logicalMetadataEventBytes, 0)
        XCTAssertEqual(snapshot.metadataTransactions, 1)
        XCTAssertEqual(snapshot.durableRepositorySaves, 1)
        XCTAssertEqual(snapshot.firstAnchorRepositorySaves, 1)
        XCTAssertEqual(snapshot.volatileRepositorySaves, 1)
        XCTAssertEqual(snapshot.duplicateRepositorySaves, 1)
        XCTAssertEqual(snapshot.repositoryExactDuplicateFrames, 1)
        let durableMutationCalls = await durable.capturedMutationCallCounts()
        XCTAssertEqual(durableMutationCalls.promoteVolatileEntry, 1)
        XCTAssertEqual(durableMutationCalls.checkpointPromotedSpan, 0)
        XCTAssertEqual(durableMutationCalls.recordEncodedCapture, 0)

        let databaseURL = directory.appendingPathComponent("frames.sqlite")
        XCTAssertEqual(try readSQLiteDouble(databaseURL: databaseURL, sql: "SELECT COUNT(*) FROM frames;"), 1)
        XCTAssertEqual(try readSQLiteDouble(databaseURL: databaseURL, sql: "SELECT COUNT(*) FROM frame_spans;"), 1)
        let frameFiles = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("frames", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(frameFiles.filter { $0.pathExtension == "jpg" }.count, 1)
        // Session begin accounts for the SQLite/WAL/SHM files in this baseline;
        // RAM captures must not introduce another durable file category.
        XCTAssertEqual(try sqliteFileNames(in: directory, baseName: "frames.sqlite"), baselineDatabaseFiles)
        let finalTextTransactions = await buffer.textCache.mutationTransactionCountForTesting()
        XCTAssertEqual(finalTextTransactions, baselineTextTransactions)
        let statistics = await buffer.storageStatistics()
        XCTAssertEqual(statistics.frameCount, 2)
        XCTAssertEqual(statistics.durableFrameCount, 1)
        XCTAssertEqual(statistics.volatileFrameCount, 1)
        XCTAssertEqual(statistics.volatileObservationCount, 2)
    }

    func testHybridExactMetricsDoNotCompareAgainstOlderDurablePayload() async throws {
        let image = try makeStructuredImage(seed: 703)
        let a = Data([1])
        let b = Data([2])
        let encoder = SequencedJPEGEncoderProbe(data: [a, b, a])
        let store = try FrameStore(directory: directory)
        let repository = HybridFrameRepository(frameStore: store, byteCap: 1_000)
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository,
            historyStorageMode: .hybridRAM(byteCap: 1_000),
            jpegEncoder: FrameJPEGEncoder { source, quality in
                encoder.encode(image: source, quality: quality)
            }
        )
        let base = Date()
        try await buffer.beginCaptureSession(at: base)

        await buffer.addFrameSync(image, timestamp: base, display: nil)
        await buffer.addFrameSync(image, timestamp: base.addingTimeInterval(0.5), display: nil)
        await buffer.addFrameSync(image, timestamp: base.addingTimeInterval(0.75), display: nil)

        let snapshot = buffer.captureInstrumentationSnapshot()
        XCTAssertEqual(snapshot.exactComparisonBaselineAvailableFrames, 2)
        XCTAssertEqual(snapshot.repositoryExactDuplicateFrames, 0)
        XCTAssertEqual(snapshot.duplicateRepositorySaves, 0)
        XCTAssertEqual(buffer.getTimelineEntries().count, 3)
    }

    func testHybridEvictionInvalidatesTimelineDecodedCacheWithoutOCRWrites() async throws {
        let firstImage = try makeStructuredImage(seed: 704)
        let secondImage = try makeStructuredImage(seed: 705)
        let firstJPEG = try XCTUnwrap(ImageEncoder.jpegData(from: firstImage, quality: 0.8))
        let secondJPEG = try XCTUnwrap(ImageEncoder.jpegData(from: secondImage, quality: 0.8))
        let encoder = SequencedJPEGEncoderProbe(data: [firstJPEG, secondJPEG])
        let store = try FrameStore(directory: directory)
        let repository = HybridFrameRepository(
            frameStore: store,
            byteCap: max(firstJPEG.count, secondJPEG.count)
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository,
            historyStorageMode: .hybridRAM(byteCap: max(firstJPEG.count, secondJPEG.count)),
            jpegEncoder: FrameJPEGEncoder { image, quality in
                encoder.encode(image: image, quality: quality)
            }
        )
        let base = Date()
        try await buffer.beginCaptureSession(at: base)
        await buffer.addFrameSync(firstImage, timestamp: base, display: nil)
        let firstEntry = try XCTUnwrap(buffer.getTimelineEntries().first)
        _ = try await buffer.getFullImage(for: firstEntry.frame)
        let baselineTextTransactions = await buffer.textCache.mutationTransactionCountForTesting()

        await buffer.addFrameSync(secondImage, timestamp: base.addingTimeInterval(1), display: nil)

        let retainedEntries = buffer.getTimelineEntries()
        XCTAssertEqual(retainedEntries.count, 2)
        XCTAssertTrue(buffer.containsTimelineSpan(id: firstEntry.span.id))
        XCTAssertTrue(buffer.containsFrame(id: firstEntry.frame.id))
        XCTAssertEqual(buffer.getFrames().map(\.id), retainedEntries.map(\.frame.id))
        _ = try await buffer.getFullImage(for: firstEntry.frame)
        let finalTextTransactions = await buffer.textCache.mutationTransactionCountForTesting()
        XCTAssertEqual(finalTextTransactions, baselineTextTransactions)
        let searchStatus = await buffer.searchIndexStatus()
        XCTAssertEqual(searchStatus.totalFrames, 2)
        XCTAssertEqual(searchStatus.indexedFrames, 0)
        XCTAssertEqual(searchStatus.queuedFrames, 0)
    }

    func testDurableInsertPromotionAndCheckpointDoNotWriteEmptyTextCacheRows() async throws {
        let image = try makeStructuredImage(seed: 707)

        let allDiskDirectory = directory.appendingPathComponent("AllDisk", isDirectory: true)
        let allDisk = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: allDiskDirectory,
            diagnosticsLog: nil,
            historyStorageMode: .allDisk
        )
        try await allDisk.beginCaptureSession(at: Date())
        let allDiskBaseline = await allDisk.textCache.mutationTransactionCountForTesting()
        await allDisk.addFrameSync(image, timestamp: Date(), display: nil)
        let allDiskFinal = await allDisk.textCache.mutationTransactionCountForTesting()
        XCTAssertEqual(allDiskFinal, allDiskBaseline)

        let firstJPEG = Data([1])
        let secondJPEG = Data([2])
        let encoder = SequencedJPEGEncoderProbe(
            data: [firstJPEG, secondJPEG, secondJPEG, secondJPEG]
        )
        let hybridDirectory = directory.appendingPathComponent("Hybrid", isDirectory: true)
        let store = try FrameStore(directory: hybridDirectory)
        let repository = HybridFrameRepository(frameStore: store, byteCap: 1_000)
        let hybrid = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: hybridDirectory,
            diagnosticsLog: nil,
            frameRepository: repository,
            historyStorageMode: .hybridRAM(byteCap: 1_000),
            jpegEncoder: FrameJPEGEncoder { image, quality in
                encoder.encode(image: image, quality: quality)
            }
        )
        let base = Date()
        try await hybrid.beginCaptureSession(at: base)
        let hybridBaseline = await hybrid.textCache.mutationTransactionCountForTesting()
        await hybrid.addFrameSync(image, timestamp: base, display: nil)
        await hybrid.addFrameSync(image, timestamp: base.addingTimeInterval(1), display: nil)
        await hybrid.addFrameSync(image, timestamp: base.addingTimeInterval(5), display: nil)
        await hybrid.addFrameSync(image, timestamp: base.addingTimeInterval(35), display: nil)

        let hybridFinal = await hybrid.textCache.mutationTransactionCountForTesting()
        XCTAssertEqual(hybridFinal, hybridBaseline)
        let metrics = hybrid.captureInstrumentationSnapshot()
        XCTAssertEqual(metrics.ordinaryAnchorRepositorySaves, 1)
        XCTAssertEqual(metrics.spanCheckpointRepositorySaves, 1)
    }

    func testHybridCheckpointAdvancesExistingTextCacheTimestampOnce() async throws {
        let image = try makeStructuredImage(seed: 708)
        let encoder = SequencedJPEGEncoderProbe(data: [Data([1]), Data([2]), Data([2]), Data([2])])
        let store = try FrameStore(directory: directory)
        let repository = HybridFrameRepository(frameStore: store, byteCap: 1_000)
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository,
            historyStorageMode: .hybridRAM(byteCap: 1_000),
            jpegEncoder: FrameJPEGEncoder { image, quality in
                encoder.encode(image: image, quality: quality)
            }
        )
        let base = Date()
        try await buffer.beginCaptureSession(at: base)
        await buffer.addFrameSync(image, timestamp: base, display: nil)
        await buffer.addFrameSync(image, timestamp: base.addingTimeInterval(1), display: nil)
        await buffer.addFrameSync(image, timestamp: base.addingTimeInterval(5), display: nil)
        let promoted = try XCTUnwrap(buffer.getTimelineEntries().last)
        await buffer.textCache.setText(
            "checkpoint recency",
            for: promoted.frame.id,
            timestamp: base.addingTimeInterval(5)
        )
        let baselineWrites = await buffer.textCache.mutationTransactionCountForTesting()

        await buffer.addFrameSync(image, timestamp: base.addingTimeInterval(35), display: nil)

        let finalWrites = await buffer.textCache.mutationTransactionCountForTesting()
        XCTAssertEqual(finalWrites, baselineWrites + 1)
        let hits = await buffer.textCache.searchFrameIDs(
            matching: "checkpoint",
            limit: 10,
            since: base.addingTimeInterval(34)
        )
        XCTAssertEqual(hits, [promoted.frame.id])
    }

    func testHybridPromotionAdvancesPreExistingVolatileTextCacheRowOnce() async throws {
        let image = try makeStructuredImage(seed: 709)
        let encoder = SequencedJPEGEncoderProbe(data: [Data([1]), Data([2]), Data([2])])
        let store = try FrameStore(directory: directory)
        let repository = HybridFrameRepository(frameStore: store, byteCap: 1_000)
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository,
            historyStorageMode: .hybridRAM(byteCap: 1_000),
            jpegEncoder: FrameJPEGEncoder { image, quality in
                encoder.encode(image: image, quality: quality)
            }
        )
        let base = Date()
        try await buffer.beginCaptureSession(at: base)
        await buffer.addFrameSync(image, timestamp: base, display: nil)
        await buffer.addFrameSync(image, timestamp: base.addingTimeInterval(1), display: nil)
        let volatile = try XCTUnwrap(buffer.getTimelineEntries().last)
        await buffer.textCache.setText(
            "promotion recency",
            for: volatile.frame.id,
            timestamp: base.addingTimeInterval(1)
        )
        let baselineWrites = await buffer.textCache.mutationTransactionCountForTesting()

        await buffer.addFrameSync(image, timestamp: base.addingTimeInterval(5), display: nil)

        let finalWrites = await buffer.textCache.mutationTransactionCountForTesting()
        XCTAssertEqual(finalWrites, baselineWrites + 1)
        let hits = await buffer.textCache.searchFrameIDs(
            matching: "promotion",
            limit: 10,
            since: base.addingTimeInterval(4)
        )
        XCTAssertEqual(hits, [volatile.frame.id])
    }

    func testHybridPostJPEGFailureIsCountedOnceAndPublishedByLaterSessionClose() async throws {
        let image = try makeStructuredImage(seed: 710)
        let jpeg = try XCTUnwrap(ImageEncoder.jpegData(from: image, quality: 0.8))
        let store = try FrameStore(
            directory: directory,
            promotionPayloadDidWrite: { _ in
                throw HybridDurableRepositoryProbeError.injectedPromotionFailure
            }
        )
        let repository = HybridFrameRepository(frameStore: store, byteCap: jpeg.count + 1)
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository,
            historyStorageMode: .hybridRAM(byteCap: jpeg.count + 1),
            jpegEncoder: FrameJPEGEncoder { _, _ in jpeg }
        )
        let base = Date()
        try await buffer.beginCaptureSession(at: base)

        await buffer.addFrameSync(image, timestamp: base, display: nil)
        XCTAssertTrue(buffer.getTimelineEntries().isEmpty)
        var metrics = buffer.captureInstrumentationSnapshot()
        XCTAssertEqual(metrics.persistedFrames, 1)
        XCTAssertEqual(metrics.durableRepositorySaves, 0)

        try await buffer.endCaptureSession(reason: .sleep)

        XCTAssertEqual(buffer.getTimelineEntries().count, 1)
        metrics = buffer.captureInstrumentationSnapshot()
        XCTAssertEqual(metrics.persistedFrames, 1)
        XCTAssertEqual(metrics.durableRepositorySaves, 1)
        XCTAssertEqual(metrics.firstAnchorRepositorySaves, 1)
        XCTAssertEqual(metrics.metadataTransactions, 1)
    }

    func testHybridPruneFailureLeavesFrameBufferTimelineAndRAMResolvable() async throws {
        let image = try makeStructuredImage(seed: 706)
        let jpeg = try XCTUnwrap(ImageEncoder.jpegData(from: image, quality: 0.8))
        let store = try FrameStore(directory: directory)
        let durable = HybridDurableRepositoryProbe(base: DiskFrameRepository(frameStore: store))
        let repository = HybridFrameRepository(durableRepository: durable, byteCap: jpeg.count + 1)
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository,
            historyStorageMode: .hybridRAM(byteCap: jpeg.count + 1),
            jpegEncoder: FrameJPEGEncoder { _, _ in jpeg }
        )
        let base = Date()
        try await buffer.beginCaptureSession(at: base)
        await buffer.addFrameSync(image, timestamp: base, display: nil)
        let entry = try XCTUnwrap(buffer.getTimelineEntries().first)
        await durable.failNextPrune()

        await buffer.updateRetentionPolicy(RetentionPolicy(tiers: []))

        XCTAssertEqual(buffer.getTimelineEntries(), [entry])
        XCTAssertTrue(buffer.containsFrame(id: entry.frame.id))
        let resolved = try await buffer.getFullImage(for: entry.frame)
        XCTAssertEqual(resolved.width, image.width)
    }

    func testHybridClearFailureRetainsKnownStateAndNextCaptureSucceeds() async throws {
        let image = try makeStructuredImage(seed: 707)
        let encoder = SequencedJPEGEncoderProbe(
            data: [Data(repeating: 1, count: 16), Data(repeating: 2, count: 16)]
        )
        let store = try FrameStore(directory: directory)
        let durable = HybridDurableRepositoryProbe(base: DiskFrameRepository(frameStore: store))
        let repository = HybridFrameRepository(durableRepository: durable, byteCap: 64)
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository,
            historyStorageMode: .hybridRAM(byteCap: 64),
            jpegEncoder: FrameJPEGEncoder { source, quality in
                encoder.encode(image: source, quality: quality)
            }
        )
        let base = Date()
        try await buffer.beginCaptureSession(at: base)
        await buffer.addFrameSync(image, timestamp: base, display: nil)
        let firstEntry = try XCTUnwrap(buffer.getTimelineEntries().first)
        await durable.failNextClear()

        do {
            try await buffer.clear()
            XCTFail("Expected injected durable clear failure")
        } catch HybridDurableRepositoryProbeError.injectedClearFailure {
            // Repository and buffer retain their pre-clear state.
        }

        XCTAssertEqual(buffer.getTimelineEntries(), [firstEntry])
        await buffer.addFrameSync(image, timestamp: base.addingTimeInterval(1), display: nil)
        XCTAssertEqual(buffer.getTimelineEntries().count, 2)
        XCTAssertTrue(buffer.containsFrame(id: firstEntry.frame.id))
    }

    func testAddFrameSyncStoresFrame() async throws {
        let buffer = try await makeBuffer()
        let image = try makeStructuredImage(seed: 1)

        await buffer.addFrameSync(image, timestamp: Date(), display: nil)

        XCTAssertEqual(buffer.frameCount, 1)
        XCTAssertEqual(buffer.getFrames().count, 1)
    }

    func testInjectedRepositoryResolvesRequestedPrefetchAndExportByStableID() async throws {
        let first = StoredFrame(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1),
            hash: 1,
            displayID: nil,
            displayName: nil
        )
        let second = StoredFrame(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 2),
            hash: 2,
            displayID: UUID(),
            displayName: "External Display"
        )
        let image = try makeStructuredImage(seed: 7)
        let exportedURL = directory.appendingPathComponent("source-neutral-export.jpg")
        let repository = FrameRepositoryProbe(
            frames: [first, second],
            image: image,
            exportedURL: exportedURL
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository
        )
        try await buffer.beginCaptureSession()

        XCTAssertEqual(buffer.getFrames(), [first, second])

        await buffer.prefetchFullImages(for: [second])
        let fullImageRequests = await repository.fullImageRequests()
        XCTAssertEqual(fullImageRequests, [second.id])

        let resolvedExport = try await buffer.saveFrameToScreenshotsLocation(first)
        XCTAssertEqual(resolvedExport, exportedURL)
        let logicalTimestamp = first.timestamp.addingTimeInterval(12)
        _ = try await buffer.saveFrameToScreenshotsLocation(first, timestamp: logicalTimestamp)
        let exportRequests = await repository.exportRequests()
        XCTAssertEqual(exportRequests.map(\.id), [first.id, first.id])
        XCTAssertEqual(exportRequests.map(\.timestamp), [first.timestamp, logicalTimestamp])

        _ = try await buffer.saveCroppedImageToScreenshotsLocation(image, timestamp: logicalTimestamp)
        let croppedExportTimestamps = await repository.croppedExportTimestamps()
        XCTAssertEqual(croppedExportTimestamps, [logicalTimestamp])

        let ocrDependencies = OCRIndexingWorkerDependencies.live(
            frameRepository: repository,
            textCache: buffer.textCache
        )
        _ = await ocrDependencies.indexFrame(second, 320)
        let searchImageRequests = await repository.searchImageRequests()
        XCTAssertEqual(searchImageRequests.map(\.id), [second.id])
        XCTAssertEqual(searchImageRequests.map(\.maxPixelSize), [320])
    }

    func testCaptureEncodesOnceOffMainAndReportsRepositoryOutcomeExactlyOnce() async throws {
        let image = try makeStructuredImage(seed: 8)
        let exactJPEG = Data([0xFF, 0xD8, 0x4A, 0x4E, 0xFF, 0xD9])
        let encoderProbe = JPEGEncoderProbe(data: exactJPEG)
        let repository = FrameRepositoryProbe(
            frames: [],
            image: image,
            exportedURL: directory.appendingPathComponent("unused.jpg"),
            saveOutcome: .durableFrame(metadataByteCount: 37)
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository,
            jpegEncoder: FrameJPEGEncoder { image, quality in
                encoderProbe.encode(image: image, quality: quality)
            }
        )
        try await buffer.beginCaptureSession()

        await buffer.addFrameSync(image, timestamp: Date(), display: nil)

        let encodingObservation = encoderProbe.observation()
        XCTAssertEqual(encodingObservation.invocationCount, 1)
        XCTAssertFalse(encodingObservation.ranOnMainThread)

        let saves = await repository.saveRequests()
        let save = try XCTUnwrap(saves.only)
        XCTAssertEqual(save.jpegData, exactJPEG)
        XCTAssertEqual(buffer.getFrames().map(\.id), [save.frame.id])

        let snapshot = buffer.captureInstrumentationSnapshot()
        XCTAssertEqual(snapshot.encodedFrames, 1)
        XCTAssertEqual(snapshot.persistedFrames, 1)
        XCTAssertEqual(snapshot.logicalDurableJPEGEventBytes, Int64(exactJPEG.count))
        XCTAssertEqual(snapshot.logicalMetadataEventBytes, 37)
        XCTAssertEqual(snapshot.metadataTransactions, 1)
        XCTAssertEqual(snapshot.durableRepositorySaves, 1)
        XCTAssertEqual(snapshot.volatileRepositorySaves, 0)
        XCTAssertEqual(snapshot.duplicateRepositorySaves, 0)
        XCTAssertEqual(snapshot.spanCheckpointRepositorySaves, 0)
    }

    func testExactExtensionAdvancesCadenceWithoutAThirdEncodeOrMetadataWrite() async throws {
        let firstImage = try makeStructuredImage(seed: 81)
        let changedImage = try makeStructuredImage(seed: 82)
        let exactJPEG = Data([0xFF, 0xD8, 0x11, 0xFF, 0xD9])
        let unexpectedJPEG = Data([0xFF, 0xD8, 0x22, 0xFF, 0xD9])
        let encoderProbe = SequencedJPEGEncoderProbe(data: [exactJPEG, exactJPEG, unexpectedJPEG])
        let repository = FrameRepositoryProbe(
            frames: [],
            image: firstImage,
            exportedURL: directory.appendingPathComponent("unused.jpg"),
            saveOutcome: .durableFrame(metadataByteCount: 37),
            coalesceExactJPEG: true
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository,
            jpegEncoder: FrameJPEGEncoder { image, quality in
                encoderProbe.encode(image: image, quality: quality)
            }
        )
        let base = Date()
        try await buffer.beginCaptureSession(at: base)

        await buffer.addFrameSync(firstImage, timestamp: base, display: nil)
        await buffer.addFrameSync(
            changedImage,
            timestamp: base.addingTimeInterval(1),
            display: nil
        )
        await buffer.addFrameSync(
            changedImage,
            timestamp: base.addingTimeInterval(1.1),
            display: nil
        )

        XCTAssertEqual(encoderProbe.invocationCount, 2)
        let saves = await repository.saveRequests()
        XCTAssertEqual(saves.count, 2)
        XCTAssertEqual(buffer.frameCount, 1)
        XCTAssertEqual(buffer.getTimelineEntries().first?.span.observationCount, 2)
        let snapshot = buffer.captureInstrumentationSnapshot()
        XCTAssertEqual(snapshot.capturedFrames, 3)
        XCTAssertEqual(snapshot.encodedFrames, 2)
        XCTAssertEqual(snapshot.metadataTransactions, 2)
        XCTAssertEqual(snapshot.persistedFrames, 1)
        XCTAssertEqual(snapshot.spanCheckpointRepositorySaves, 1)
        XCTAssertEqual(snapshot.logicalDurableJPEGEventBytes, Int64(exactJPEG.count))
    }

    func testFirstOCRWriteAfterSpanExtensionUsesCurrentLogicalTimestampForSinceSearch() async throws {
        let firstImage = try makeStructuredImage(seed: 211)
        let extensionImage = try makeStructuredImage(seed: 212)
        let exactJPEG = Data([0xFF, 0xD8, 0x31, 0xFF, 0xD9])
        let encoderProbe = SequencedJPEGEncoderProbe(data: [exactJPEG])
        let repository = FrameRepositoryProbe(
            frames: [],
            image: firstImage,
            exportedURL: directory.appendingPathComponent("unused.jpg"),
            coalesceExactJPEG: true
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository,
            jpegEncoder: FrameJPEGEncoder { image, quality in
                encoderProbe.encode(image: image, quality: quality)
            }
        )
        let base = Date()
        let extendedAt = base.addingTimeInterval(5)
        try await buffer.beginCaptureSession(at: base.addingTimeInterval(-1))

        await buffer.addFrameSync(firstImage, timestamp: base, display: nil)
        let queuedFrame = try XCTUnwrap(buffer.getFrames().first)
        let hadCachedText = await buffer.textCache.hasCachedText(for: queuedFrame.id)
        XCTAssertFalse(hadCachedText)

        await buffer.addFrameSync(extensionImage, timestamp: extendedAt, display: nil)
        XCTAssertEqual(
            try XCTUnwrap(buffer.getFrames().first?.timestamp).timeIntervalSince1970,
            extendedAt.timeIntervalSince1970,
            accuracy: 0.000_001
        )

        let cached = await buffer.cacheOCRTextIfCurrent(
            "first OCR after extension",
            for: queuedFrame
        )
        let recentHits = await buffer.textCache.searchFrameIDs(
            matching: "first OCR",
            limit: 10,
            since: base.addingTimeInterval(4)
        )
        XCTAssertTrue(cached)
        XCTAssertEqual(recentHits, [queuedFrame.id])
    }

    func testFirstSearchLayoutWriteAfterSpanExtensionUsesCurrentLogicalTimestamp() async throws {
        let firstImage = try makeStructuredImage(seed: 213)
        let extensionImage = try makeStructuredImage(seed: 214)
        let exactJPEG = Data([0xFF, 0xD8, 0x32, 0xFF, 0xD9])
        let encoderProbe = SequencedJPEGEncoderProbe(data: [exactJPEG])
        let repository = FrameRepositoryProbe(
            frames: [],
            image: firstImage,
            exportedURL: directory.appendingPathComponent("unused.jpg"),
            coalesceExactJPEG: true
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository,
            jpegEncoder: FrameJPEGEncoder { image, quality in
                encoderProbe.encode(image: image, quality: quality)
            }
        )
        let base = Date()
        let extendedAt = base.addingTimeInterval(5)
        try await buffer.beginCaptureSession(at: base.addingTimeInterval(-1))

        await buffer.addFrameSync(firstImage, timestamp: base, display: nil)
        let queuedFrame = try XCTUnwrap(buffer.getFrames().first)
        let missingLayout = await buffer.textCache.getSearchLayout(for: queuedFrame.id)
        XCTAssertNil(missingLayout)

        await buffer.addFrameSync(extensionImage, timestamp: extendedAt, display: nil)
        let layout = SearchTextLayout(
            lines: [
                SearchTextLine(
                    text: "Fresh layout",
                    rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1),
                    words: []
                )
            ]
        )
        let cached = await buffer.cacheSearchLayoutIfCurrent(layout, for: queuedFrame)
        let restoredLayout = await buffer.textCache.getSearchLayout(for: queuedFrame.id)
        let cachedTimestamp = try readSQLiteDouble(
            databaseURL: directory.appendingPathComponent("text_cache.sqlite"),
            sql:
                """
                SELECT updated_at
                FROM frame_search_layout
                WHERE frame_id = '\(queuedFrame.id.uuidString)';
                """
        )

        XCTAssertTrue(cached)
        XCTAssertEqual(restoredLayout?.lines.first?.text, "Fresh layout")
        XCTAssertEqual(
            cachedTimestamp,
            extendedAt.timeIntervalSince1970,
            accuracy: 0.000_001
        )
    }

    func testSuspendedSaveCrossingClearIsPrunedAndRetriedInFreshEpoch() async throws {
        let image = try makeStructuredImage(seed: 9)
        let exactJPEG = Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9])
        let encoderProbe = JPEGEncoderProbe(data: exactJPEG)
        let repository = FrameRepositoryProbe(
            frames: [],
            image: image,
            exportedURL: directory.appendingPathComponent("unused.jpg"),
            saveOutcome: .durableFrame(metadataByteCount: 19),
            suspendFirstSave: true
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository,
            jpegEncoder: FrameJPEGEncoder { image, quality in
                encoderProbe.encode(image: image, quality: quality)
            }
        )
        try await buffer.beginCaptureSession()

        let pendingCapture = Task {
            await buffer.addFrameSync(image, timestamp: Date(), display: nil)
        }
        await repository.waitForSaveInvocation(count: 1)
        let firstSaveRequests = await repository.saveRequests()
        _ = try XCTUnwrap(firstSaveRequests.first?.frame.id)

        try await buffer.clear()
        await repository.resumeSuspendedSave()
        await pendingCapture.value

        let saves = await repository.saveRequests()
        XCTAssertEqual(saves.count, 2)
        XCTAssertNotEqual(saves[0].frame.id, saves[1].frame.id)
        let prunedFrameIDs = await repository.prunedFrameIDs()
        let clearInvocationCount = await repository.clearInvocationCount()
        XCTAssertTrue(prunedFrameIDs.isEmpty)
        XCTAssertEqual(buffer.getFrames().map(\.id), [saves[1].frame.id])
        XCTAssertEqual(clearInvocationCount, 1)

        let snapshot = buffer.captureInstrumentationSnapshot()
        XCTAssertEqual(snapshot.epoch, 1)
        XCTAssertEqual(snapshot.encodedFrames, 1)
        XCTAssertEqual(snapshot.persistedFrames, 1)
        XCTAssertEqual(snapshot.durableRepositorySaves, 1)
        XCTAssertEqual(snapshot.metadataTransactions, 1)
    }

    func testEndingSessionWaitsForAcceptedSaveBeforeClosingRepositorySession() async throws {
        let image = try makeStructuredImage(seed: 91)
        let repository = FrameRepositoryProbe(
            frames: [],
            image: image,
            exportedURL: directory.appendingPathComponent("unused.jpg"),
            suspendFirstSave: true
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository
        )
        try await buffer.beginCaptureSession()
        let pendingCapture = Task {
            await buffer.addFrameSync(image, timestamp: Date(), display: nil)
        }
        await repository.waitForSaveInvocation(count: 1)

        let pendingEnd = Task {
            try await buffer.endCaptureSession(reason: .termination)
        }
        await Task.yield()
        let reasonsBeforeSaveCompletes = await repository.recordedEndReasons()
        XCTAssertTrue(reasonsBeforeSaveCompletes.isEmpty)

        await repository.resumeSuspendedSave()
        await pendingCapture.value
        try await pendingEnd.value

        let endReasons = await repository.recordedEndReasons()
        XCTAssertEqual(endReasons, [.termination])
        XCTAssertEqual(buffer.frameCount, 1)
    }

    func testEndThenBeginSerialisesAcrossSuspendedSaveAndCreatesDistinctSession() async throws {
        let image = try makeStructuredImage(seed: 93)
        let repository = FrameRepositoryProbe(
            frames: [],
            image: image,
            exportedURL: directory.appendingPathComponent("unused.jpg"),
            suspendFirstSave: true
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository
        )
        let base = Date()
        let firstSession = try await buffer.beginCaptureSession(at: base)
        let pendingCapture = Task {
            await buffer.addFrameSync(image, timestamp: base, display: nil)
        }
        await repository.waitForSaveInvocation(count: 1)

        let pendingEnd = Task {
            try await buffer.endCaptureSession(reason: .sleep)
        }
        await Task.yield()
        let pendingBegin = Task {
            try await buffer.beginCaptureSession(at: base.addingTimeInterval(10))
        }
        await Task.yield()
        let begunBeforeSaveCompletes = await repository.begunSessionIDs()
        XCTAssertEqual(begunBeforeSaveCompletes, [firstSession.id])

        await repository.resumeSuspendedSave()
        await pendingCapture.value
        try await pendingEnd.value
        let secondSession = try await pendingBegin.value

        XCTAssertNotEqual(secondSession.id, firstSession.id)
        let begunSessionIDs = await repository.begunSessionIDs()
        XCTAssertEqual(begunSessionIDs, [firstSession.id, secondSession.id])
        await buffer.addFrameSync(
            try makeStructuredImage(seed: 94),
            timestamp: base.addingTimeInterval(10),
            display: nil
        )
        XCTAssertEqual(buffer.frameCount, 2)
    }

    func testFailedBeginRollsBackCaptureAcceptanceAndCanRetry() async throws {
        let image = try makeStructuredImage(seed: 95)
        let repository = FrameRepositoryProbe(
            frames: [],
            image: image,
            exportedURL: directory.appendingPathComponent("unused.jpg"),
            beginFailures: 1
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository
        )
        let base = Date()

        do {
            _ = try await buffer.beginCaptureSession(at: base)
            XCTFail("Expected injected begin failure")
        } catch FrameRepositoryProbeError.beginFailed {
        }
        await buffer.addFrameSync(image, timestamp: base, display: nil)
        let savesAfterFailedBegin = await repository.saveRequests()
        XCTAssertTrue(savesAfterFailedBegin.isEmpty)

        _ = try await buffer.beginCaptureSession(at: base.addingTimeInterval(1))
        await buffer.addFrameSync(
            image,
            timestamp: base.addingTimeInterval(1),
            display: nil
        )
        XCTAssertEqual(buffer.frameCount, 1)
    }

    func testFailedEndIsRetriedBeforeDistinctLaterBegin() async throws {
        let image = try makeStructuredImage(seed: 96)
        let repository = FrameRepositoryProbe(
            frames: [],
            image: image,
            exportedURL: directory.appendingPathComponent("unused.jpg"),
            endFailures: 1
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository
        )
        let base = Date()
        let first = try await buffer.beginCaptureSession(at: base)

        do {
            try await buffer.endCaptureSession(reason: .sessionInactive)
            XCTFail("Expected injected end failure")
        } catch FrameRepositoryProbeError.endFailed {
        }
        let second = try await buffer.beginCaptureSession(at: base.addingTimeInterval(10))

        XCTAssertNotEqual(first.id, second.id)
        let recordedEndReasons = await repository.recordedEndReasons()
        XCTAssertEqual(recordedEndReasons, [.sessionInactive, .sessionInactive])
        let begunSessionIDs = await repository.begunSessionIDs()
        XCTAssertEqual(begunSessionIDs, [first.id, second.id])
        await buffer.addFrameSync(
            image,
            timestamp: base.addingTimeInterval(10),
            display: nil
        )
        XCTAssertEqual(buffer.frameCount, 1)
    }

    func testTerminationFlushRetriesPendingCloseWithOriginalReason() async throws {
        let image = try makeStructuredImage(seed: 961)
        let repository = FrameRepositoryProbe(
            frames: [],
            image: image,
            exportedURL: directory.appendingPathComponent("unused.jpg"),
            endFailures: 1
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository
        )
        _ = try await buffer.beginCaptureSession()

        do {
            try await buffer.endCaptureSession(reason: .termination)
            XCTFail("Expected injected close failure")
        } catch FrameRepositoryProbeError.endFailed {
        }

        await buffer.flushCaches()

        let reasons = await repository.recordedEndReasons()
        XCTAssertEqual(reasons, [.termination, .termination])
        let sessionIsActive = await repository.captureSessionIsActive()
        XCTAssertFalse(sessionIsActive)
    }

    func testClearReopenFailureRecoversOnLaterFrameWithoutManualRestart() async throws {
        let image = try makeStructuredImage(seed: 962)
        let repository = FrameRepositoryProbe(
            frames: [],
            image: image,
            exportedURL: directory.appendingPathComponent("unused.jpg")
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository
        )
        _ = try await buffer.beginCaptureSession()
        await repository.setBeginFailures(1)

        do {
            try await buffer.clear()
            XCTFail("Expected post-clear reopen failure")
        } catch is FrameBufferClearError {
        }
        XCTAssertEqual(buffer.frameCount, 0)

        await buffer.addFrameSync(image, timestamp: Date(), display: nil)

        XCTAssertEqual(buffer.frameCount, 1)
        let saves = await repository.saveRequests()
        XCTAssertEqual(saves.count, 1)
        let begunSessions = await repository.begunSessionIDs()
        XCTAssertEqual(begunSessions.count, 2)
    }

    func testClearRecoveryKeepsOnlyNewestPendingFramePerDisplay() async throws {
        let image = try makeStructuredImage(seed: 963)
        let repository = FrameRepositoryProbe(
            frames: [],
            image: image,
            exportedURL: directory.appendingPathComponent("unused.jpg")
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository
        )
        _ = try await buffer.beginCaptureSession()
        await repository.setBeginFailures(1)
        do {
            try await buffer.clear()
            XCTFail("Expected post-clear reopen failure")
        } catch is FrameBufferClearError {
        }

        let base = Date()
        for offset in 0..<20 {
            buffer.addFrame(
                image,
                timestamp: base.addingTimeInterval(TimeInterval(offset)),
                display: nil
            )
        }
        await repository.waitForSaveInvocation(count: 1)

        let saves = await repository.saveRequests()
        XCTAssertEqual(saves.count, 1)
        XCTAssertEqual(saves.first?.frame.timestamp, base.addingTimeInterval(19))
        while buffer.frameCount < 1 {
            await Task.yield()
        }
        try await buffer.endCaptureSession(reason: .paused)
    }

    func testClearFencesRecoveryFrameQueuedBeforeTheNewHistoryEpoch() async throws {
        let image = try makeStructuredImage(seed: 964)
        let repository = FrameRepositoryProbe(
            frames: [],
            image: image,
            exportedURL: directory.appendingPathComponent("unused.jpg")
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository
        )
        _ = try await buffer.beginCaptureSession()
        await repository.setBeginFailures(1)
        do {
            try await buffer.clear()
            XCTFail("Expected post-clear reopen failure")
        } catch is FrameBufferClearError {
        }

        await repository.suspendNextBegin()
        buffer.addFrame(image, timestamp: Date(), display: nil)
        await repository.waitForBeginInvocation(count: 3)

        let replacementClear = Task { @MainActor in
            try await buffer.clear()
        }
        await Task.yield()
        await repository.resumeSuspendedBegin()
        try await replacementClear.value
        await Task.yield()

        let saves = await repository.saveRequests()
        XCTAssertTrue(saves.isEmpty)
        XCTAssertEqual(buffer.frameCount, 0)
        try await buffer.endCaptureSession(reason: .paused)
    }

    func testStopDuringClearPreventsSessionFromReopening() async throws {
        let image = try makeStructuredImage(seed: 92)
        let repository = FrameRepositoryProbe(
            frames: [],
            image: image,
            exportedURL: directory.appendingPathComponent("unused.jpg"),
            suspendClear: true
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository
        )
        try await buffer.beginCaptureSession()

        let pendingClear = Task {
            try await buffer.clear()
        }
        await repository.waitForClearInvocation()
        let pendingStop = Task {
            try await buffer.endCaptureSession(reason: .sleep)
        }
        await Task.yield()

        await repository.resumeSuspendedClear()
        try await pendingClear.value
        try await pendingStop.value
        await buffer.addFrameSync(image, timestamp: Date(), display: nil)

        XCTAssertEqual(buffer.frameCount, 0)
        let endReasons = await repository.recordedEndReasons()
        XCTAssertTrue(endReasons.isEmpty, "Clear already removed the active session")
        let sessionIsActive = await repository.captureSessionIsActive()
        XCTAssertFalse(sessionIsActive)
    }

    func testRepositoryReceivesRetentionPruneFlushAndClearDelegation() async throws {
        let oldFrame = StoredFrame(
            id: UUID(),
            timestamp: Date().addingTimeInterval(-60),
            hash: 1,
            displayID: nil,
            displayName: nil
        )
        let image = try makeStructuredImage(seed: 10)
        let repository = FrameRepositoryProbe(
            frames: [oldFrame],
            image: image,
            exportedURL: directory.appendingPathComponent("unused.jpg")
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository
        )
        try await buffer.beginCaptureSession()

        await buffer.updateRetentionPolicy(
            RetentionPolicy(tiers: [RetentionTier(maxAge: 1, minimumSpacing: 0)])
        )
        await buffer.flushCaches()
        try await buffer.clear()

        let prunedFrameIDs = await repository.prunedFrameIDs()
        let flushInvocationCount = await repository.flushInvocationCount()
        let clearInvocationCount = await repository.clearInvocationCount()
        XCTAssertEqual(Set(prunedFrameIDs), [oldFrame.id])
        XCTAssertEqual(flushInvocationCount, 1)
        XCTAssertEqual(clearInvocationCount, 1)
    }

    func testRetentionUsesLogicalSpanRecencyAndPrunesOnlyExpiredSpan() async throws {
        let now = Date()
        let recentPhysicalFrame = StoredFrame(
            id: UUID(),
            timestamp: now.addingTimeInterval(-100),
            hash: 11,
            displayID: nil,
            displayName: nil
        )
        let expiredPhysicalFrame = StoredFrame(
            id: UUID(),
            timestamp: now.addingTimeInterval(-50),
            hash: 22,
            displayID: nil,
            displayName: nil
        )
        let sessionID = UUID()
        let recentSpanID = UUID()
        let expiredSpanID = UUID()
        let timeline = [
            TimelineEntry(
                span: TimelineSpan(
                    id: expiredSpanID,
                    frameID: expiredPhysicalFrame.id,
                    sessionID: sessionID,
                    startedAt: expiredPhysicalFrame.timestamp,
                    observedThroughAt: expiredPhysicalFrame.timestamp,
                    observationCount: 1,
                    displayID: nil,
                    displayName: nil
                ),
                frame: expiredPhysicalFrame
            ),
            TimelineEntry(
                span: TimelineSpan(
                    id: recentSpanID,
                    frameID: recentPhysicalFrame.id,
                    sessionID: sessionID,
                    startedAt: recentPhysicalFrame.timestamp,
                    observedThroughAt: now,
                    observationCount: 7,
                    displayID: nil,
                    displayName: nil
                ),
                frame: recentPhysicalFrame
            )
        ]
        let repository = FrameRepositoryProbe(
            frames: [recentPhysicalFrame, expiredPhysicalFrame],
            image: try makeStructuredImage(seed: 101),
            exportedURL: directory.appendingPathComponent("unused.jpg"),
            timeline: timeline
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository
        )

        await buffer.updateRetentionPolicy(
            RetentionPolicy(tiers: [RetentionTier(maxAge: 10, minimumSpacing: 0)])
        )

        XCTAssertEqual(buffer.getTimelineEntries().map(\.span.id), [recentSpanID])
        XCTAssertEqual(buffer.getFrames().map(\.id), [recentPhysicalFrame.id])
        XCTAssertEqual(buffer.getFrames().map(\.timestamp), [now])
        let prunedSpanIDs = await repository.prunedFrameIDs()
        XCTAssertEqual(prunedSpanIDs, [expiredSpanID])
    }

    func testPruningFinalSpanExplicitlyDeletesOCRAndLayoutFromEmptyHistory() async throws {
        let frame = StoredFrame(
            id: UUID(),
            timestamp: Date().addingTimeInterval(-120),
            hash: 31,
            displayID: nil,
            displayName: nil
        )
        let repository = FrameRepositoryProbe(
            frames: [frame],
            image: try makeStructuredImage(seed: 102),
            exportedURL: directory.appendingPathComponent("unused.jpg")
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository
        )
        await buffer.textCache.setText("final physical frame", for: frame.id, timestamp: frame.timestamp)
        await buffer.textCache.setSearchLayout(
            SearchTextLayout(lines: []),
            for: frame.id,
            timestamp: frame.timestamp
        )

        await buffer.updateRetentionPolicy(
            RetentionPolicy(tiers: [RetentionTier(maxAge: 1, minimumSpacing: 0)])
        )

        XCTAssertTrue(buffer.getTimelineEntries().isEmpty)
        let hasText = await buffer.textCache.hasCachedText(for: frame.id)
        let layout = await buffer.textCache.getSearchLayout(for: frame.id)
        XCTAssertFalse(hasText)
        XCTAssertNil(layout)
    }

    func testPruneFenceRejectsOCRWhilePhysicalFrameRemovalIsInFlight() async throws {
        let frame = StoredFrame(
            id: UUID(),
            timestamp: Date().addingTimeInterval(-120),
            hash: 32,
            displayID: nil,
            displayName: nil
        )
        let repository = FrameRepositoryProbe(
            frames: [frame],
            image: try makeStructuredImage(seed: 103),
            exportedURL: directory.appendingPathComponent("unused.jpg"),
            suspendFirstPrune: true
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository
        )
        let projectedFrame = try XCTUnwrap(buffer.getFrames().first)

        let pendingPrune = Task { @MainActor in
            await buffer.updateRetentionPolicy(
                RetentionPolicy(tiers: [RetentionTier(maxAge: 1, minimumSpacing: 0)])
            )
        }
        await repository.waitForPruneInvocation()

        let cached = await buffer.cacheOCRTextIfCurrent("must not survive", for: projectedFrame)
        XCTAssertFalse(cached)
        await repository.resumeSuspendedPrune()
        await pendingPrune.value

        let hasText = await buffer.textCache.hasCachedText(for: frame.id)
        XCTAssertFalse(hasText)
    }

    /// Regression: uniform solid-colour frames used to hash to 0, which the
    /// dedupe path treats as the "no hash" legacy sentinel, so every capture
    /// of a static solid screen was stored. They must dedupe like any other
    /// identical frame within the minimum spacing window.
    func testIdenticalUniformFramesWithinSpacingAreDeduplicated() async throws {
        let buffer = try await makeBuffer()
        let uniform = try XCTUnwrap(TestImageFactory.makeSolidImage(width: 32, height: 32, level: 40))
        let base = Date()

        await buffer.addFrameSync(uniform, timestamp: base, display: nil)
        await buffer.addFrameSync(uniform, timestamp: base.addingTimeInterval(0.1), display: nil)

        XCTAssertEqual(buffer.frameCount, 1)
        let snapshot = buffer.captureInstrumentationSnapshot()
        XCTAssertEqual(snapshot.capturedFrames, 2)
        XCTAssertEqual(snapshot.encodedFrames, 1, "Span persistence must not increase pHash cadence")
    }

    func testIdenticalFramesBeyondMinimumSpacingExtendOneDurableSpan() async throws {
        let buffer = try await makeBuffer()
        let uniform = try XCTUnwrap(TestImageFactory.makeSolidImage(width: 32, height: 32, level: 40))
        let base = Date()

        await buffer.addFrameSync(uniform, timestamp: base, display: nil)
        await buffer.addFrameSync(uniform, timestamp: base.addingTimeInterval(1.0), display: nil)

        XCTAssertEqual(buffer.frameCount, 1)
        let statistics = await buffer.storageStatistics()
        XCTAssertEqual(statistics.frameCount, 1)
        XCTAssertEqual(statistics.timelineSpanCount, 1)
        XCTAssertEqual(statistics.observationCount, 2)
    }

    func testInstrumentationObservesExistingPersistenceWithoutChangingDedupe() async throws {
        let buffer = try await makeBuffer()
        let uniform = try XCTUnwrap(TestImageFactory.makeSolidImage(width: 32, height: 32, level: 40))
        let base = Date()

        await buffer.addFrameSync(uniform, timestamp: base, display: nil)
        await buffer.addFrameSync(uniform, timestamp: base.addingTimeInterval(1), display: nil)
        await buffer.flushCaches()

        let snapshot = buffer.captureInstrumentationSnapshot()
        XCTAssertEqual(buffer.frameCount, 1)
        XCTAssertEqual(snapshot.capturedFrames, 2)
        XCTAssertEqual(snapshot.encodedFrames, 2)
        XCTAssertEqual(snapshot.persistedFrames, 1)
        XCTAssertEqual(snapshot.durableRepositorySaves, 1)
        XCTAssertEqual(snapshot.spanCheckpointRepositorySaves, 1)
        XCTAssertEqual(snapshot.exactComparisonEligibleFrames, 2)
        XCTAssertEqual(snapshot.exactComparisonBaselineAvailableFrames, 1)
        XCTAssertEqual(snapshot.exactComparisonSkippedFrames, 0)
        XCTAssertEqual(snapshot.perceptuallyEqualFrames, 1)
        XCTAssertEqual(snapshot.repositoryExactDuplicateFrames, 1)
        XCTAssertEqual(snapshot.logicalDurableJPEGEventBytes, Int64(snapshot.largestEncodedJPEGBytes))
        XCTAssertEqual(snapshot.metadataTransactions, 2)
        XCTAssertGreaterThan(snapshot.logicalMetadataEventBytes, 0)
        XCTAssertGreaterThanOrEqual(snapshot.maximumIngestQueueDepth, 1)
    }

    func testCaptureFlushEmitsOneAggregateCaptureMetricsLine() async throws {
        let diagnosticsLog = InMemoryCaptureMetricsLog()
        let buffer = try await makeBuffer(diagnosticsLog: diagnosticsLog)
        let image = try makeStructuredImage(seed: 1)

        await buffer.addFrameSync(image, timestamp: Date(), display: nil)
        await buffer.flushCaches()

        XCTAssertEqual(diagnosticsLog.entries.count, 1)
        let entry = try XCTUnwrap(diagnosticsLog.entries.first)
        XCTAssertEqual(entry.category, "CaptureMetrics")
        XCTAssertTrue(entry.message.contains("captured=1"))
        XCTAssertTrue(entry.message.contains("encoded=1"))
        XCTAssertTrue(entry.message.contains("durableJPEGEvents=1"))
        XCTAssertTrue(entry.message.contains("logicalJPEGEventBytes="))
        XCTAssertFalse(entry.message.contains("TestImageFactory"))
    }

    func testClearResetsInstrumentationEpochAndExactComparisonBaseline() async throws {
        let buffer = try await makeBuffer()
        let uniform = try XCTUnwrap(TestImageFactory.makeSolidImage(width: 32, height: 32, level: 40))
        let base = Date()

        await buffer.addFrameSync(uniform, timestamp: base, display: nil)
        await buffer.addFrameSync(uniform, timestamp: base.addingTimeInterval(1), display: nil)
        try await buffer.clear()

        let afterClear = buffer.captureInstrumentationSnapshot()
        XCTAssertEqual(afterClear.epoch, 1)
        XCTAssertEqual(afterClear.capturedFrames, 0)
        XCTAssertEqual(afterClear.persistedFrames, 0)
        XCTAssertEqual(afterClear.currentTrackedDisplays, 0)

        await buffer.addFrameSync(uniform, timestamp: base.addingTimeInterval(2), display: nil)
        let afterNewCapture = buffer.captureInstrumentationSnapshot()
        XCTAssertEqual(afterNewCapture.capturedFrames, 1)
        XCTAssertEqual(afterNewCapture.exactComparisonEligibleFrames, 1)
        XCTAssertEqual(afterNewCapture.exactComparisonBaselineAvailableFrames, 0)
        XCTAssertEqual(afterNewCapture.repositoryExactDuplicateFrames, 0)
    }

    func testVisuallyDistinctFramesWithinSpacingAreBothStored() async throws {
        let buffer = try await makeBuffer()
        let base = Date()

        await buffer.addFrameSync(try makeStructuredImage(seed: 1), timestamp: base, display: nil)
        await buffer.addFrameSync(
            try makeStructuredImage(seed: 2),
            timestamp: base.addingTimeInterval(0.1),
            display: nil
        )

        XCTAssertEqual(buffer.frameCount, 2)
    }

    func testDedupeIsScopedPerDisplay() async throws {
        let buffer = try await makeBuffer()
        let uniform = try XCTUnwrap(TestImageFactory.makeSolidImage(width: 32, height: 32, level: 40))
        let base = Date()
        let displayA = DisplayInfo(id: UUID(), displayID: 1, name: "A")
        let displayB = DisplayInfo(id: UUID(), displayID: 2, name: "B")

        await buffer.addFrameSync(uniform, timestamp: base, display: displayA)
        await buffer.addFrameSync(uniform, timestamp: base.addingTimeInterval(0.1), display: displayB)

        // The same pixels arriving on a different display are not duplicates.
        XCTAssertEqual(buffer.frameCount, 2)
    }

    func testGetFilteredFramesFiltersByDisplayAndIncludesLegacyOnRequest() async throws {
        let buffer = try await makeBuffer()
        let base = Date().addingTimeInterval(-10)
        let displayA = DisplayInfo(id: UUID(), displayID: 1, name: "A")
        let displayB = DisplayInfo(id: UUID(), displayID: 2, name: "B")

        await buffer.addFrameSync(try makeStructuredImage(seed: 1), timestamp: base, display: displayA)
        await buffer.addFrameSync(
            try makeStructuredImage(seed: 2),
            timestamp: base.addingTimeInterval(1),
            display: displayB
        )
        await buffer.addFrameSync(
            try makeStructuredImage(seed: 3),
            timestamp: base.addingTimeInterval(2),
            display: nil
        )

        let displayAOnly = buffer.getFilteredFrames(displayID: displayA.id)
        XCTAssertEqual(displayAOnly.map(\.displayID), [displayA.id])

        let displayAWithLegacy = buffer.getFilteredFrames(
            displayID: displayA.id,
            includeLegacyFrames: true
        )
        XCTAssertEqual(displayAWithLegacy.count, 2)
        XCTAssertEqual(displayAWithLegacy.compactMap(\.displayID), [displayA.id])
    }

    func testFilteredTimelineUsesObservedThroughForAgeAndPreservesSpanIdentity() async throws {
        let now = Date()
        let physical = StoredFrame(
            id: UUID(),
            timestamp: now.addingTimeInterval(-3_600),
            hash: 0xAA,
            displayID: nil,
            displayName: nil
        )
        let recentSpan = TimelineEntry(
            span: TimelineSpan(
                id: UUID(),
                frameID: physical.id,
                sessionID: UUID(),
                startedAt: now.addingTimeInterval(-3_600),
                observedThroughAt: now.addingTimeInterval(-10),
                observationCount: 4,
                displayID: nil,
                displayName: nil
            ),
            frame: physical
        )
        let repository = FrameRepositoryProbe(
            frames: [physical],
            image: try makeStructuredImage(seed: 180),
            exportedURL: directory.appendingPathComponent("unused.jpg"),
            timeline: [recentSpan]
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository
        )

        let entries = buffer.getFilteredTimelineEntries(
            recentWindow: 30,
            maximumAge: 60,
            now: now
        )

        XCTAssertEqual(entries.map(\.span.id), [recentSpan.span.id])
        XCTAssertEqual(entries.only?.frame.id, physical.id)
        XCTAssertEqual(buffer.getFilteredFrames(maximumAge: 60, now: now).only?.timestamp, recentSpan.span.observedThroughAt)
    }

    func testRollbackSpanUsesNormalisedEndForFilteringAndSearchCutoff() async throws {
        let now = Date()
        let physical = StoredFrame(
            id: UUID(),
            timestamp: now.addingTimeInterval(-10),
            hash: 0xAB,
            displayID: nil,
            displayName: nil
        )
        let rollback = TimelineEntry(
            span: TimelineSpan(
                id: UUID(),
                frameID: physical.id,
                sessionID: UUID(),
                startedAt: now.addingTimeInterval(-10),
                observedThroughAt: now.addingTimeInterval(-3_600),
                observationCount: 2,
                displayID: nil,
                displayName: nil
            ),
            frame: physical
        )
        let repository = FrameRepositoryProbe(
            frames: [physical],
            image: try makeStructuredImage(seed: 183),
            exportedURL: directory.appendingPathComponent("unused.jpg"),
            timeline: [rollback]
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository
        )

        XCTAssertEqual(
            buffer.getFilteredTimelineEntries(maximumAge: 60, now: now).map(\.span.id),
            [rollback.span.id]
        )
        XCTAssertEqual(
            buffer.timelineEntries(
                matchingPhysicalFrameIDs: [physical.id],
                since: now.addingTimeInterval(-60)
            ).map(\.span.id),
            [rollback.span.id]
        )
    }

    func testTimelineSearchMapsOnePhysicalCacheIDToEveryQualifyingLogicalSpan() async throws {
        let now = Date()
        let physical = StoredFrame(
            id: UUID(),
            timestamp: now.addingTimeInterval(-120),
            hash: 10,
            displayID: nil,
            displayName: nil
        )
        let sessionID = UUID()
        func entry(startOffset: TimeInterval, endOffset: TimeInterval) -> TimelineEntry {
            TimelineEntry(
                span: TimelineSpan(
                    id: UUID(),
                    frameID: physical.id,
                    sessionID: sessionID,
                    startedAt: now.addingTimeInterval(startOffset),
                    observedThroughAt: now.addingTimeInterval(endOffset),
                    observationCount: 2,
                    displayID: nil,
                    displayName: nil
                ),
                frame: physical
            )
        }
        let old = entry(startOffset: -120, endOffset: -110)
        let recent = entry(startOffset: -20, endOffset: -10)
        let repository = FrameRepositoryProbe(
            frames: [physical],
            image: try makeStructuredImage(seed: 181),
            exportedURL: directory.appendingPathComponent("unused.jpg"),
            timeline: [old, recent]
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository
        )

        XCTAssertEqual(
            buffer.timelineEntries(matchingPhysicalFrameIDs: [physical.id]).map(\.span.id),
            [old.span.id, recent.span.id]
        )
        XCTAssertEqual(
            buffer.timelineEntries(
                matchingPhysicalFrameIDs: [physical.id],
                since: now.addingTimeInterval(-60)
            ).map(\.span.id),
            [recent.span.id]
        )
    }

    func testFilteredTimelineKeepsRecentCadenceAndCollapsesOlderNearDuplicates() async throws {
        let now = Date()
        let sessionID = UUID()
        func entry(offset: TimeInterval) -> TimelineEntry {
            let frame = StoredFrame(
                id: UUID(),
                timestamp: now.addingTimeInterval(offset),
                hash: 0xF0,
                displayID: nil,
                displayName: nil
            )
            return TimelineEntry(
                span: TimelineSpan(
                    id: UUID(),
                    frameID: frame.id,
                    sessionID: sessionID,
                    startedAt: frame.timestamp,
                    observedThroughAt: frame.timestamp,
                    observationCount: 1,
                    displayID: nil,
                    displayName: nil
                ),
                frame: frame
            )
        }
        let entries = [entry(offset: -1_000), entry(offset: -900), entry(offset: -20), entry(offset: -10)]
        let repository = FrameRepositoryProbe(
            frames: entries.map(\.frame),
            image: try makeStructuredImage(seed: 182),
            exportedURL: directory.appendingPathComponent("unused.jpg"),
            timeline: entries
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository
        )

        XCTAssertEqual(
            buffer.getFilteredTimelineEntries(recentWindow: 60, now: now).map(\.span.id),
            [entries[0].span.id, entries[2].span.id, entries[3].span.id]
        )
    }

    func testUnscopedTimelineDedupeKeepsIndependentPerDisplayBaselines() async throws {
        let now = Date()
        let displayA = UUID()
        let displayB = UUID()
        let sessionID = UUID()
        func entry(offset: TimeInterval, displayID: UUID?) -> TimelineEntry {
            let frame = StoredFrame(
                id: UUID(),
                timestamp: now.addingTimeInterval(offset),
                hash: 0xF0,
                displayID: displayID,
                displayName: nil
            )
            return TimelineEntry(
                span: TimelineSpan(
                    id: UUID(),
                    frameID: frame.id,
                    sessionID: sessionID,
                    startedAt: frame.timestamp,
                    observedThroughAt: frame.timestamp,
                    observationCount: 1,
                    displayID: displayID,
                    displayName: nil
                ),
                frame: frame
            )
        }
        let firstA = entry(offset: -1_000, displayID: displayA)
        let firstB = entry(offset: -900, displayID: displayB)
        let firstLegacy = entry(offset: -850, displayID: nil)
        let secondA = entry(offset: -800, displayID: displayA)
        let secondLegacy = entry(offset: -750, displayID: nil)
        let entries = [firstA, firstB, firstLegacy, secondA, secondLegacy]
        let repository = FrameRepositoryProbe(
            frames: entries.map(\.frame),
            image: try makeStructuredImage(seed: 184),
            exportedURL: directory.appendingPathComponent("unused.jpg"),
            timeline: entries
        )
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository
        )

        XCTAssertEqual(
            buffer.getFilteredTimelineEntries(recentWindow: 60, now: now).map(\.span.id),
            [firstA.span.id, firstB.span.id, firstLegacy.span.id]
        )
    }

    func testKnownDisplaysOrdersMostRecentFirst() async throws {
        let buffer = try await makeBuffer()
        let base = Date()
        let displayA = DisplayInfo(id: UUID(), displayID: 1, name: "A")
        let displayB = DisplayInfo(id: UUID(), displayID: 2, name: "B")

        await buffer.addFrameSync(try makeStructuredImage(seed: 1), timestamp: base, display: displayA)
        await buffer.addFrameSync(
            try makeStructuredImage(seed: 2),
            timestamp: base.addingTimeInterval(1),
            display: displayB
        )

        XCTAssertEqual(buffer.knownDisplays().map(\.name), ["B", "A"])
        XCTAssertFalse(buffer.hasLegacyFrames)
    }

    func testReopenPreservesLogicalRecencyDisplaysAndSearchTimestampForExtendedSpan() async throws {
        let base = Date()
        let displayA = DisplayInfo(id: UUID(), displayID: 1, name: "A")
        let displayB = DisplayInfo(id: UUID(), displayID: 2, name: "B")
        let imageA = try makeStructuredImage(seed: 111)
        let imageB = try makeStructuredImage(seed: 112)
        let frameAID: UUID

        do {
            let buffer = try await FrameBuffer(
                retentionPolicy: .default24Hours,
                storageDirectory: directory,
                diagnosticsLog: nil,
                historyStorageMode: .allDisk
            )
            try await buffer.beginCaptureSession(at: base.addingTimeInterval(-1))
            await buffer.addFrameSync(imageA, timestamp: base, display: displayA)
            let frameA = try XCTUnwrap(buffer.getFrames().first)
            frameAID = frameA.id
            _ = await buffer.cacheOCRTextIfCurrent("logical recency survives reopen", for: frameA)
            await buffer.addFrameSync(
                imageB,
                timestamp: base.addingTimeInterval(1),
                display: displayB
            )
            await buffer.addFrameSync(
                imageA,
                timestamp: base.addingTimeInterval(2),
                display: displayA
            )
            try await buffer.endCaptureSession(reason: .termination)
            await buffer.flushCaches()
        }

        let reopened = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            historyStorageMode: .allDisk
        )
        let frames = reopened.getFrames()
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames.last?.id, frameAID)
        XCTAssertEqual(
            try XCTUnwrap(frames.last?.timestamp).timeIntervalSince1970,
            base.addingTimeInterval(2).timeIntervalSince1970,
            accuracy: 0.000_001
        )
        XCTAssertEqual(reopened.knownDisplays().map(\.name), ["A", "B"])
        let matches = await reopened.textCache.searchFrameIDs(
            matching: "logical recency",
            limit: 10,
            since: base.addingTimeInterval(1.5)
        )
        XCTAssertEqual(matches, [frameAID])
        let cachedCount = await reopened.textCache.count
        XCTAssertEqual(cachedCount, 1)
    }

    func testEqualTimestampLiveOrderMatchesReopenedDurableOrder() async throws {
        let base = Date()
        let displayA = DisplayInfo(id: UUID(), displayID: 1, name: "A")
        let displayB = DisplayInfo(id: UUID(), displayID: 2, name: "B")
        let liveTimelineIDs: [UUID]
        let liveFrameIDs: [UUID]
        do {
            let buffer = try await FrameBuffer(
                retentionPolicy: .default24Hours,
                storageDirectory: directory,
                diagnosticsLog: nil,
                historyStorageMode: .allDisk
            )
            try await buffer.beginCaptureSession(at: base.addingTimeInterval(-1))
            await buffer.addFrameSync(
                try makeStructuredImage(seed: 201),
                timestamp: base,
                display: displayA
            )
            await buffer.addFrameSync(
                try makeStructuredImage(seed: 202),
                timestamp: base,
                display: displayB
            )
            liveTimelineIDs = buffer.getTimelineEntries().map(\.span.id)
            liveFrameIDs = buffer.getFrames().map(\.id)
            try await buffer.endCaptureSession(reason: .termination)
            await buffer.flushCaches()
        }

        let reopened = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            historyStorageMode: .allDisk
        )

        XCTAssertEqual(reopened.getTimelineEntries().map(\.span.id), liveTimelineIDs)
        XCTAssertEqual(reopened.getFrames().map(\.id), liveFrameIDs)
    }

    func testClearEmptiesBufferAndDiskAndStaysUsable() async throws {
        let buffer = try await makeBuffer()
        let base = Date()
        await buffer.addFrameSync(try makeStructuredImage(seed: 1), timestamp: base, display: nil)
        await buffer.addFrameSync(
            try makeStructuredImage(seed: 2),
            timestamp: base.addingTimeInterval(1),
            display: nil
        )

        try await buffer.clear()

        XCTAssertEqual(buffer.frameCount, 0)
        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: framesDirectory.path)
        XCTAssertEqual(files, [".store-id"])

        // The buffer must accept new captures after a clear.
        await buffer.addFrameSync(
            try makeStructuredImage(seed: 3),
            timestamp: base.addingTimeInterval(2),
            display: nil
        )
        XCTAssertEqual(buffer.frameCount, 1)
    }

    /// A capture timestamped before the fresh post-clear session must neither
    /// deadlock nor leak back into cleared history.
    func testClearDuringPendingSyncIngestDoesNotCrossTheNewSessionBoundary() async throws {
        let buffer = try await makeBuffer()
        let image = try makeStructuredImage(seed: 1)

        let pendingCapture = Task {
            await buffer.addFrameSync(image, timestamp: Date(), display: nil)
        }
        try await buffer.clear()
        await pendingCapture.value

        XCTAssertEqual(buffer.frameCount, 0)
    }

    /// Firing far more async captures than the ingest backlog allows must
    /// keep the buffer internally consistent (ordered, lookup in sync) while
    /// older backlog entries are shed.
    func testAsyncIngestBacklogSheddingKeepsBufferConsistent() async throws {
        let buffer = try await makeBuffer()
        let base = Date().addingTimeInterval(-60)

        for index in 0..<20 {
            buffer.addFrame(
                try makeStructuredImage(seed: index),
                timestamp: base.addingTimeInterval(Double(index)),
                display: nil
            )
        }
        await buffer.flushCaches()

        let frames = buffer.getFrames()
        XCTAssertFalse(frames.isEmpty)
        XCTAssertLessThanOrEqual(frames.count, 20)

        let timestamps = frames.map(\.timestamp)
        XCTAssertEqual(timestamps, timestamps.sorted(), "Frames must stay chronologically ordered")
        for frame in frames {
            XCTAssertTrue(buffer.containsFrame(id: frame.id))
        }
        XCTAssertEqual(buffer.frames(withIDs: frames.map(\.id)).map(\.id), frames.map(\.id))

        let snapshot = buffer.captureInstrumentationSnapshot()
        XCTAssertEqual(snapshot.capturedFrames, 20)
        XCTAssertEqual(snapshot.maximumPreTrimIngestQueueDepth, 7)
        XCTAssertEqual(snapshot.maximumIngestQueueDepth, 6)
        XCTAssertEqual(snapshot.droppedAsyncIngests, 14)
        XCTAssertEqual(snapshot.droppedAsyncIngestsForBacklogLimit, 14)
        XCTAssertEqual(snapshot.droppedAsyncIngestsForSyncPriority, 0)
    }

    func testSyncIngestPriorityRecordsDiscardedAsyncBacklog() async throws {
        let buffer = try await makeBuffer()
        let image = try makeStructuredImage(seed: 1)
        let base = Date()

        for index in 0..<6 {
            buffer.addFrame(image, timestamp: base.addingTimeInterval(TimeInterval(index)), display: nil)
        }
        await buffer.addFrameSync(image, timestamp: base.addingTimeInterval(10), display: nil)
        await buffer.flushCaches()

        let snapshot = buffer.captureInstrumentationSnapshot()
        XCTAssertEqual(snapshot.maximumPreTrimIngestQueueDepth, 6)
        XCTAssertEqual(snapshot.maximumIngestQueueDepth, 6)
        XCTAssertEqual(snapshot.droppedAsyncIngests, 6)
        XCTAssertEqual(snapshot.droppedAsyncIngestsForSyncPriority, 6)
        XCTAssertEqual(snapshot.droppedAsyncIngestsForBacklogLimit, 0)
    }

    /// A corrupt frame database starts the buffer empty; the init-time text-cache
    /// prune must not treat that empty frame set as licence to wipe the whole
    /// OCR index.
    func testCorruptFrameDatabaseDoesNotWipeTextCacheOnInit() async throws {
        let frameID: UUID
        do {
            let buffer = try await makeBuffer()
            await buffer.addFrameSync(try makeStructuredImage(seed: 1), timestamp: Date(), display: nil)
            let frame = try XCTUnwrap(buffer.getFrames().first)
            frameID = frame.id
            _ = await buffer.cacheOCRTextIfCurrent("hello world", for: frame)
            await buffer.flushCaches()
        }

        try Data("not a sqlite database".utf8).write(
            to: directory.appendingPathComponent("frames.sqlite"),
            options: .atomic
        )

        let reopened = try await makeBuffer()

        XCTAssertEqual(reopened.frameCount, 0)
        let cachedCount = await reopened.textCache.count
        XCTAssertEqual(cachedCount, 1)
        let hasText = await reopened.textCache.hasCachedText(for: frameID)
        XCTAssertTrue(hasText)
    }

    func testVersionOneMigrationPreservesFrameIdentityAndItsOCRCache() async throws {
        let frame: FrameMetadata
        do {
            let store = try FrameStore(directory: directory)
            frame = try await store.saveFrame(
                makeStructuredImage(seed: 71),
                timestamp: Date(timeIntervalSince1970: 7_100),
                hash: 71,
                displayID: nil,
                displayName: nil
            )
            await store.flush()
        }
        do {
            let textCache = TextCache(directory: directory)
            await textCache.setText("preserved legacy OCR", for: frame.id, timestamp: frame.timestamp)
        }
        try executeSQLite(
            databaseURL: directory.appendingPathComponent("frames.sqlite"),
            sql:
                """
                PRAGMA foreign_keys=OFF;
                DROP TABLE frame_spans;
                DROP TABLE capture_sessions;
                PRAGMA user_version=1;
                """
        )

        let reopened = try await makeBuffer()

        XCTAssertEqual(reopened.getFrames().map(\.id), [frame.id])
        let hasCachedText = await reopened.textCache.hasCachedText(for: frame.id)
        let searchMatches = await reopened.textCache.searchFrameIDs(
            matching: "preserved legacy",
            limit: 10
        )
        XCTAssertTrue(hasCachedText)
        XCTAssertEqual(searchMatches, [frame.id])
    }

    func testStartupDoesNotMaterialiseFrameWhoseFullImageIsMissing() async throws {
        let frameID: UUID
        do {
            let buffer = try await makeBuffer()
            await buffer.addFrameSync(try makeStructuredImage(seed: 1), timestamp: Date(), display: nil)
            frameID = try XCTUnwrap(buffer.getFrames().first?.id)
            await buffer.flushCaches()
        }

        let missingImageURL = directory
            .appendingPathComponent("frames", isDirectory: true)
            .appendingPathComponent("\(frameID.uuidString).jpg")
        try FileManager.default.removeItem(at: missingImageURL)

        let reopened = try await makeBuffer()

        XCTAssertEqual(reopened.frameCount, 0)
        XCTAssertFalse(reopened.containsFrame(id: frameID))
    }

    /// Deterministic pattern per seed with strong structural differences so
    /// perceptual hashes are far apart between seeds.
    private func makeTimelineEntry(at timestamp: Date, hash: UInt64) -> TimelineEntry {
        let frame = StoredFrame(
            id: UUID(),
            timestamp: timestamp,
            hash: hash,
            displayID: nil,
            displayName: nil
        )
        return TimelineEntry(
            span: TimelineSpan(
                id: UUID(),
                frameID: frame.id,
                sessionID: UUID(),
                startedAt: timestamp,
                observedThroughAt: timestamp,
                observationCount: 1,
                displayID: nil,
                displayName: nil
            ),
            frame: frame
        )
    }

    private func makeStructuredImage(seed: Int) throws -> CGImage {
        try XCTUnwrap(
            TestImageFactory.makeImage(width: 64, height: 64) { x, y in
                let band = ((x / 8) + seed) % 2 == 0
                let stripe = ((y / 8) &* (seed + 3)) % 3 == 0
                return band != stripe ? (240, 240, 240) : (10, 10, 10)
            }
        )
    }

    private func executeSQLite(databaseURL: URL, sql: String) throws {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let connection else {
            throw FrameDatabaseError.sqlite("Failed to open test database")
        }
        defer { sqlite3_close(connection) }
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw FrameDatabaseError.sqlite("Failed to prepare version 1 test database")
        }
    }

    private func sqliteFileNames(in directory: URL, baseName: String) throws -> Set<String> {
        Set(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            .map(\.lastPathComponent)
            .filter { $0 == baseName || $0.hasPrefix("\(baseName)-") }
        )
    }

    private func readSQLiteDouble(databaseURL: URL, sql: String) throws -> Double {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let connection else {
            throw FrameDatabaseError.sqlite("Failed to open test database")
        }
        defer { sqlite3_close(connection) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw FrameDatabaseError.sqlite("Failed to prepare test query")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw FrameDatabaseError.sqlite("Test query returned no row")
        }
        return sqlite3_column_double(statement, 0)
    }
}

private actor BlockingMaintenancePayloadLease: FrameRepositoryPayloadLease {
    private let result: FrameRepositoryMaintenanceResult
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    init(result: FrameRepositoryMaintenanceResult) {
        self.result = result
    }

    func release() async -> FrameRepositoryMaintenanceResult {
        let waiters = requestWaiters
        requestWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return result
    }

    func waitUntilReleaseRequested() async {
        guard releaseContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func permitRelease() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor FrameRepositoryProbe: FrameRepository {
    struct SaveRequest: Sendable {
        let frame: StoredFrame
        let jpegData: Data
    }

    private var frames: [StoredFrame]
    private var spans: [TimelineEntry]
    private var activeSession: CaptureSession?
    private let image: CGImage
    private let exportedURL: URL
    private let saveOutcome: FrameRepositorySaveOutcome
    private var shouldSuspendFirstSave: Bool
    private var shouldSuspendClear: Bool
    private var shouldSuspendFirstPrune: Bool
    private var shouldSuspendFirstPressure: Bool
    private var shouldSuspendFirstFullImage: Bool
    private var clearFailuresRemaining: Int
    private var beginFailuresRemaining: Int
    private var shouldSuspendNextBegin = false
    private var beginInvocationCount = 0
    private var endFailuresRemaining: Int
    private let coalesceExactJPEG: Bool
    private var jpegByFrameID: [UUID: Data] = [:]
    private var fullImageRequestIDs: [UUID] = []
    private var searchImageRequestValues: [(id: UUID, maxPixelSize: Int)] = []
    private var exportRequestValues: [(id: UUID, timestamp: Date)] = []
    private var croppedExportTimestampValues: [Date] = []
    private var saveRequestValues: [SaveRequest] = []
    private var prunedFrameIDValues: [UUID] = []
    private var clearInvocations = 0
    private var flushInvocations = 0
    private var endReasonValues: [CaptureSessionEndReason] = []
    private var begunSessionIDValues: [UUID] = []
    private var saveWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var beginWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var suspendedBeginContinuation: CheckedContinuation<Void, Never>?
    private var suspendedSaveContinuation: CheckedContinuation<Void, Never>?
    private var clearWaiters: [CheckedContinuation<Void, Never>] = []
    private var suspendedClearContinuation: CheckedContinuation<Void, Never>?
    private var pruneWaiters: [CheckedContinuation<Void, Never>] = []
    private var suspendedPruneContinuation: CheckedContinuation<Void, Never>?
    private var pruneInvocations = 0
    private let pressureResult: FrameRepositoryMaintenanceResult
    private var pressureContinuation: CheckedContinuation<Void, Never>?
    private var pressureWaiters: [CheckedContinuation<Void, Never>] = []
    private var fullImageContinuation: CheckedContinuation<Void, Never>?
    private var fullImageWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        frames: [StoredFrame],
        image: CGImage,
        exportedURL: URL,
        saveOutcome: FrameRepositorySaveOutcome = .volatileFrame,
        suspendFirstSave: Bool = false,
        suspendClear: Bool = false,
        suspendFirstPrune: Bool = false,
        suspendFirstPressure: Bool = false,
        suspendFirstFullImage: Bool = false,
        clearFailures: Int = 0,
        pressureResult: FrameRepositoryMaintenanceResult = .noOp,
        beginFailures: Int = 0,
        endFailures: Int = 0,
        coalesceExactJPEG: Bool = false,
        timeline: [TimelineEntry]? = nil
    ) {
        self.frames = frames
        let historicalSession = CaptureSession(
            id: UUID(),
            startedAt: frames.first?.timestamp ?? Date(timeIntervalSince1970: 0),
            endedAt: frames.last?.timestamp ?? Date(timeIntervalSince1970: 0),
            endReason: .legacyMigration
        )
        self.spans = timeline ?? frames.map { frame in
            TimelineEntry(
                span: TimelineSpan(
                    id: frame.id,
                    frameID: frame.id,
                    sessionID: historicalSession.id,
                    startedAt: frame.timestamp,
                    observedThroughAt: frame.timestamp,
                    observationCount: 1,
                    displayID: frame.displayID,
                    displayName: frame.displayName
                ),
                frame: frame
            )
        }
        self.activeSession = nil
        self.image = image
        self.exportedURL = exportedURL
        self.saveOutcome = saveOutcome
        self.shouldSuspendFirstSave = suspendFirstSave
        self.shouldSuspendClear = suspendClear
        self.shouldSuspendFirstPrune = suspendFirstPrune
        self.shouldSuspendFirstPressure = suspendFirstPressure
        self.shouldSuspendFirstFullImage = suspendFirstFullImage
        self.clearFailuresRemaining = clearFailures
        self.pressureResult = pressureResult
        self.beginFailuresRemaining = beginFailures
        self.endFailuresRemaining = endFailures
        self.coalesceExactJPEG = coalesceExactJPEG
    }

    func cleanupOrphans() {}

    func orderedFrames() -> [StoredFrame] {
        frames
    }

    func orderedTimeline() -> [TimelineEntry] {
        spans
    }

    func beginCaptureSession(at startedAt: Date) async throws -> CaptureSession {
        beginInvocationCount += 1
        let beginWaitersToResume = beginWaiters.filter { $0.count <= beginInvocationCount }
        beginWaiters.removeAll { $0.count <= beginInvocationCount }
        for waiter in beginWaitersToResume {
            waiter.continuation.resume()
        }
        if beginFailuresRemaining > 0 {
            beginFailuresRemaining -= 1
            throw FrameRepositoryProbeError.beginFailed
        }
        if shouldSuspendNextBegin {
            shouldSuspendNextBegin = false
            await withCheckedContinuation { continuation in
                suspendedBeginContinuation = continuation
            }
        }
        if activeSession != nil {
            throw FrameRepositoryProbeError.sessionMismatch
        }
        let session = CaptureSession(id: UUID(), startedAt: startedAt, endedAt: nil, endReason: nil)
        activeSession = session
        begunSessionIDValues.append(session.id)
        return session
    }

    func endCaptureSession(
        id: UUID,
        reason: CaptureSessionEndReason
    ) throws -> FrameRepositoryEffects {
        endReasonValues.append(reason)
        if endFailuresRemaining > 0 {
            endFailuresRemaining -= 1
            throw FrameRepositoryProbeError.endFailed
        }
        guard activeSession?.id == id else {
            throw FrameRepositoryProbeError.sessionMismatch
        }
        activeSession = nil
        return .empty
    }

    func recordEncodedCapture(
        _ frame: StoredFrame,
        jpegData: Data
    ) async -> FrameRepositorySaveResult {
        saveRequestValues.append(SaveRequest(frame: frame, jpegData: jpegData))
        resumeSatisfiedSaveWaiters()
        if shouldSuspendFirstSave {
            shouldSuspendFirstSave = false
            await withCheckedContinuation { continuation in
                suspendedSaveContinuation = continuation
            }
        }
        if coalesceExactJPEG,
           let priorIndex = spans.indices.last,
           jpegByFrameID[spans[priorIndex].frame.id] == jpegData,
           spans[priorIndex].span.displayID == frame.displayID {
            let prior = spans[priorIndex]
            let extended = TimelineSpan(
                id: prior.span.id,
                frameID: prior.span.frameID,
                sessionID: prior.span.sessionID,
                startedAt: prior.span.startedAt,
                observedThroughAt: frame.timestamp,
                observationCount: prior.span.observationCount + 1,
                displayID: prior.span.displayID,
                displayName: frame.displayName ?? prior.span.displayName
            )
            spans[priorIndex] = TimelineEntry(span: extended, frame: prior.frame)
            return FrameRepositorySaveResult(
                mutation: .extended(extended),
                outcome: .spanCheckpoint(metadataByteCount: 8)
            )
        }
        frames.append(frame)
        let sessionID = activeSession?.id ?? UUID()
        let entry = TimelineEntry(
            span: TimelineSpan(
                id: frame.id,
                frameID: frame.id,
                sessionID: sessionID,
                startedAt: frame.timestamp,
                observedThroughAt: frame.timestamp,
                observationCount: 1,
                displayID: frame.displayID,
                displayName: frame.displayName
            ),
            frame: frame
        )
        spans.append(entry)
        jpegByFrameID[frame.id] = jpegData
        return FrameRepositorySaveResult(mutation: .inserted(entry), outcome: saveOutcome)
    }

    func loadFullImage(id: UUID) async -> CGImage {
        fullImageRequestIDs.append(id)
        if shouldSuspendFirstFullImage {
            shouldSuspendFirstFullImage = false
            let waiters = fullImageWaiters
            fullImageWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                fullImageContinuation = continuation
            }
        }
        return image
    }

    func loadThumbnail(id: UUID) -> CGImage? {
        image
    }

    func loadSearchIndexImage(id: UUID, maxPixelSize: Int) -> CGImage {
        searchImageRequestValues.append((id: id, maxPixelSize: maxPixelSize))
        return image
    }

    func exportFrame(id: UUID, timestamp: Date) -> URL {
        exportRequestValues.append((id: id, timestamp: timestamp))
        return exportedURL
    }

    func exportCroppedImage(_ image: CGImage, timestamp: Date) -> URL {
        croppedExportTimestampValues.append(timestamp)
        return exportedURL
    }

    func pruneSpans(ids: Set<UUID>) async -> FrameRepositoryInvalidation {
        pruneInvocations += 1
        let waiters = pruneWaiters
        pruneWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        if shouldSuspendFirstPrune {
            shouldSuspendFirstPrune = false
            await withCheckedContinuation { continuation in
                suspendedPruneContinuation = continuation
            }
        }
        prunedFrameIDValues.append(contentsOf: ids)
        let candidateFrameIDs = Set(
            spans.lazy.filter { ids.contains($0.span.id) }.map(\.frame.id)
        )
        spans.removeAll { ids.contains($0.span.id) }
        let stillReferenced = Set(spans.map(\.frame.id))
        let removed = candidateFrameIDs.subtracting(stillReferenced)
        frames.removeAll { removed.contains($0.id) }
        for id in removed {
            jpegByFrameID.removeValue(forKey: id)
        }
        return FrameRepositoryInvalidation(spanIDs: ids, finalPhysicalFrameIDs: removed)
    }

    func respondToMemoryPressure(
        _ level: FrameMemoryPressureLevel
    ) async -> FrameRepositoryMaintenanceResult {
        if shouldSuspendFirstPressure {
            shouldSuspendFirstPressure = false
            let waiters = pressureWaiters
            pressureWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                pressureContinuation = continuation
            }
        }
        return pressureResult
    }

    func clear() async throws {
        clearInvocations += 1
        let waiters = clearWaiters
        clearWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        if shouldSuspendClear {
            shouldSuspendClear = false
            await withCheckedContinuation { continuation in
                suspendedClearContinuation = continuation
            }
        }
        if clearFailuresRemaining > 0 {
            clearFailuresRemaining -= 1
            throw FrameRepositoryProbeError.clearFailed
        }
        frames.removeAll()
        spans.removeAll()
        activeSession = nil
        jpegByFrameID.removeAll()
    }

    func durableJPEGPayloadBytes() -> Int64 {
        0
    }

    func storageStatistics() -> FrameStorageStatistics {
        .empty
    }

    func flush() {
        flushInvocations += 1
    }

    func fullImageRequests() -> [UUID] {
        fullImageRequestIDs
    }

    func exportRequests() -> [(id: UUID, timestamp: Date)] {
        exportRequestValues
    }

    func croppedExportTimestamps() -> [Date] {
        croppedExportTimestampValues
    }

    func searchImageRequests() -> [(id: UUID, maxPixelSize: Int)] {
        searchImageRequestValues
    }

    func saveRequests() -> [SaveRequest] {
        saveRequestValues
    }

    func prunedFrameIDs() -> [UUID] {
        prunedFrameIDValues
    }

    func clearInvocationCount() -> Int {
        clearInvocations
    }

    func flushInvocationCount() -> Int {
        flushInvocations
    }

    func recordedEndReasons() -> [CaptureSessionEndReason] {
        endReasonValues
    }

    func captureSessionIsActive() -> Bool {
        activeSession != nil
    }

    func begunSessionIDs() -> [UUID] {
        begunSessionIDValues
    }

    func setBeginFailures(_ count: Int) {
        beginFailuresRemaining = count
    }

    func suspendNextBegin() {
        shouldSuspendNextBegin = true
    }

    func waitForBeginInvocation(count: Int) async {
        guard beginInvocationCount < count else { return }
        await withCheckedContinuation { continuation in
            beginWaiters.append((count: count, continuation: continuation))
        }
    }

    func resumeSuspendedBegin() {
        let continuation = suspendedBeginContinuation
        suspendedBeginContinuation = nil
        continuation?.resume()
    }

    func waitForSaveInvocation(count: Int) async {
        guard saveRequestValues.count < count else { return }
        await withCheckedContinuation { continuation in
            saveWaiters.append((count: count, continuation: continuation))
        }
    }

    func resumeSuspendedSave() {
        let continuation = suspendedSaveContinuation
        suspendedSaveContinuation = nil
        continuation?.resume()
    }

    func waitForClearInvocation() async {
        guard clearInvocations == 0 else { return }
        await withCheckedContinuation { continuation in
            clearWaiters.append(continuation)
        }
    }

    func resumeSuspendedClear() {
        let continuation = suspendedClearContinuation
        suspendedClearContinuation = nil
        continuation?.resume()
    }

    func waitForPruneInvocation() async {
        guard pruneInvocations == 0 else { return }
        await withCheckedContinuation { continuation in
            pruneWaiters.append(continuation)
        }
    }

    func resumeSuspendedPrune() {
        let continuation = suspendedPruneContinuation
        suspendedPruneContinuation = nil
        continuation?.resume()
    }

    func waitForPressureInvocation() async {
        guard shouldSuspendFirstPressure == false else {
            await withCheckedContinuation { continuation in
                pressureWaiters.append(continuation)
            }
            return
        }
    }

    func resumeSuspendedPressure() {
        pressureContinuation?.resume()
        pressureContinuation = nil
    }

    func waitForFullImageInvocation() async {
        guard shouldSuspendFirstFullImage else { return }
        await withCheckedContinuation { continuation in
            fullImageWaiters.append(continuation)
        }
    }

    func resumeSuspendedFullImage() {
        fullImageContinuation?.resume()
        fullImageContinuation = nil
    }

    private func resumeSatisfiedSaveWaiters() {
        var pending: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in saveWaiters {
            if saveRequestValues.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        saveWaiters = pending
    }
}

nonisolated private final class JPEGEncoderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data
    private var invocationCount = 0
    private var ranOnMainThread = false

    init(data: Data) {
        self.data = data
    }

    func encode(image: CGImage, quality: CGFloat) -> Data? {
        lock.lock()
        invocationCount += 1
        ranOnMainThread = ranOnMainThread || Thread.isMainThread
        lock.unlock()
        return data
    }

    func observation() -> (invocationCount: Int, ranOnMainThread: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (invocationCount, ranOnMainThread)
    }
}

nonisolated private final class SequencedJPEGEncoderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let data: [Data]
    private var nextIndex = 0

    init(data: [Data]) {
        precondition(!data.isEmpty)
        self.data = data
    }

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return nextIndex
    }

    func encode(image: CGImage, quality: CGFloat) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let result = data[min(nextIndex, data.count - 1)]
        nextIndex += 1
        return result
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
