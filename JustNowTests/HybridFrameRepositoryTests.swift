import CoreGraphics
import Foundation
import XCTest
@testable import JustNow

final class HybridFrameRepositoryTests: XCTestCase {
    private var directory: URL!
    private var exportDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HybridFrameRepositoryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        exportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HybridFrameRepositoryExports-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: exportDirectory)
        try super.tearDownWithError()
    }

    func testRingHasOneStrictGlobalFIFOAcrossDisplays() async throws {
        let ring = CompressedFrameRing(byteCap: 8)
        let sessionID = UUID()
        let first = makeFrame(at: 1, displayID: UUID())
        let second = makeFrame(at: 2, displayID: UUID())
        let third = makeFrame(at: 3, displayID: first.displayID)

        guard case .inserted = await ring.admit(
            frame: first,
            jpegData: Data(repeating: 1, count: 4),
            sessionID: sessionID
        ), case .inserted = await ring.admit(
            frame: second,
            jpegData: Data(repeating: 2, count: 4),
            sessionID: sessionID
        ), case .inserted(_, let eviction) = await ring.admit(
            frame: third,
            jpegData: Data(repeating: 3, count: 4),
            sessionID: sessionID
        ) else {
            return XCTFail("Expected each payload to fit under the global cap")
        }

        XCTAssertEqual(eviction.entries.map(\.frame.id), [first.id])
        let retainedEntries = await ring.entries()
        XCTAssertEqual(retainedEntries.map(\.frame.id), [second.id, third.id])
        let statistics = await ring.statistics()
        XCTAssertEqual(statistics.totalBytes, 8)
        XCTAssertEqual(statistics.byteCap, 8)
        XCTAssertEqual(statistics.payloadCount, 2)
    }

    func testWarningLowersEffectiveCapAndLeaseReleaseCompletesDeferredFIFOTrim() async throws {
        let ring = CompressedFrameRing(byteCap: 16)
        let sessionID = UUID()
        let first = makeFrame(at: 1, displayID: UUID())
        let second = makeFrame(at: 2, displayID: UUID())
        guard case .inserted = await ring.admit(
            frame: first,
            jpegData: Data(repeating: 1, count: 8),
            sessionID: sessionID
        ), case .inserted = await ring.admit(
            frame: second,
            jpegData: Data(repeating: 2, count: 8),
            sessionID: sessionID
        ) else {
            return XCTFail("Expected both payloads to fit")
        }
        let leased = await ring.acquireLease(for: [first.id])

        let warning = await ring.reduceForWarning()

        XCTAssertEqual(warning.targetBytes, 4)
        XCTAssertEqual(warning.bytesBefore, 16)
        XCTAssertEqual(warning.bytesAfter, 8)
        XCTAssertEqual(warning.eviction.entries.map(\.frame.id), [second.id])
        let retainedWhileLeased = await ring.data(frameID: first.id)
        XCTAssertNotNil(retainedWhileLeased)

        let release = await ring.releaseLease(for: leased)
        XCTAssertEqual(release.bytesAfter, 0)
        XCTAssertEqual(release.eviction.entries.map(\.frame.id), [first.id])
        let statistics = await ring.statistics()
        XCTAssertEqual(statistics.byteCap, 4)
        XCTAssertEqual(statistics.configuredByteCap, 16)
        let third = makeFrame(at: 3, displayID: nil)
        guard case .needsDurableSpill = await ring.admit(
            frame: third,
            jpegData: Data(repeating: 3, count: 8),
            sessionID: sessionID
        ) else {
            return XCTFail("The warning cap must remain effective for the launch")
        }
    }

    func testCriticalPressurePreservesUnknownLeaseThenPurgesItOnRelease() async throws {
        let ring = CompressedFrameRing(byteCap: 16)
        let sessionID = UUID()
        let first = makeFrame(at: 1, displayID: nil)
        let second = makeFrame(at: 2, displayID: nil)
        _ = await ring.admit(frame: first, jpegData: Data(repeating: 1, count: 8), sessionID: sessionID)
        _ = await ring.admit(frame: second, jpegData: Data(repeating: 2, count: 8), sessionID: sessionID)
        let leased = await ring.acquireLease(for: [first.id])

        let critical = await ring.dropAllForCriticalPressure()

        XCTAssertEqual(critical.targetBytes, 0)
        XCTAssertEqual(critical.bytesAfter, 8)
        XCTAssertEqual(critical.eviction.entries.map(\.frame.id), [second.id])
        let retainedWhileLeased = await ring.data(frameID: first.id)
        XCTAssertNotNil(retainedWhileLeased)

        let release = await ring.releaseLease(for: leased)
        XCTAssertEqual(release.bytesAfter, 0)
        XCTAssertEqual(release.eviction.entries.map(\.frame.id), [first.id])
        let retainedAfterRelease = await ring.data(frameID: first.id)
        XCTAssertNil(retainedAfterRelease)
    }

    func testCriticalRepositoryMaintenanceDropsRAMWithoutDurableMutation() async throws {
        let store = try FrameStore(directory: directory)
        let durable = HybridDurableRepositoryProbe(base: DiskFrameRepository(frameStore: store))
        let repository = HybridFrameRepository(durableRepository: durable, byteCap: 64)
        let displayID = UUID()
        _ = try await repository.beginCaptureSession(at: Date(timeIntervalSince1970: 0))
        let anchor = makeFrame(at: 0, displayID: displayID, hash: 1)
        let volatile = makeFrame(at: 1, displayID: displayID, hash: 3)
        _ = try await repository.recordEncodedCapture(anchor, jpegData: Data(repeating: 1, count: 16))
        _ = try await repository.recordEncodedCapture(volatile, jpegData: Data(repeating: 2, count: 16))
        await durable.resetMutationCallCounts()

        let result = await repository.respondToMemoryPressure(.critical)

        XCTAssertEqual(result.targetBytes, 0)
        XCTAssertEqual(result.bytesAfter, 0)
        let mutationCounts = await durable.capturedMutationCallCounts()
        XCTAssertEqual(mutationCounts, .zero)
        let timeline = await repository.orderedTimeline()
        XCTAssertEqual(timeline.map(\.frame.id), [anchor.id])
        let statistics = await repository.storageStatistics()
        XCTAssertEqual(statistics.volatileBytes, 0)
        XCTAssertEqual(statistics.volatileByteCap, 0)
        XCTAssertEqual(statistics.configuredVolatileByteCap, 64)
        XCTAssertEqual(statistics.durableFrameCount, 1)
        XCTAssertEqual(statistics.frameCount, 1)
    }

    func testZeroPressureCapDropsNonAnchorsInsteadOfSpillingEveryCapture() async throws {
        let store = try FrameStore(directory: directory)
        let durable = HybridDurableRepositoryProbe(base: DiskFrameRepository(frameStore: store))
        let repository = HybridFrameRepository(durableRepository: durable, byteCap: 64)
        let displayID = UUID()
        _ = try await repository.beginCaptureSession(at: Date(timeIntervalSince1970: 0))
        let anchor = makeFrame(at: 0, displayID: displayID, hash: 1)
        _ = try await repository.recordEncodedCapture(anchor, jpegData: Data(repeating: 1, count: 16))
        _ = await repository.respondToMemoryPressure(.critical)
        await durable.resetMutationCallCounts()

        let nonAnchor = makeFrame(at: 1, displayID: displayID, hash: 3)
        let dropped = try await repository.recordEncodedCapture(
            nonAnchor,
            jpegData: Data(repeating: 2, count: 16)
        )

        XCTAssertEqual(dropped.mutation, .none)
        XCTAssertEqual(dropped.outcome.disposition, .pressureDrop)
        var counts = await durable.capturedMutationCallCounts()
        XCTAssertEqual(counts, .zero)

        let dueAnchor = makeFrame(at: 5, displayID: displayID, hash: 7)
        _ = try await repository.recordEncodedCapture(
            dueAnchor,
            jpegData: Data(repeating: 3, count: 16)
        )
        counts = await durable.capturedMutationCallCounts()
        XCTAssertEqual(counts.promoteVolatileEntry, 1)
    }

    func testPressureDropBreaksExactDuplicateContinuityAcrossMissingContent() async throws {
        let store = try FrameStore(directory: directory)
        let repository = HybridFrameRepository(frameStore: store, byteCap: 64)
        let displayID = UUID()
        _ = try await repository.beginCaptureSession(at: Date(timeIntervalSince1970: 0))
        let firstA = makeFrame(at: 0, displayID: displayID, hash: 1)
        let aJPEG = Data(repeating: 1, count: 16)
        _ = try await repository.recordEncodedCapture(firstA, jpegData: aJPEG)
        _ = await repository.respondToMemoryPressure(.critical)

        let droppedB = try await repository.recordEncodedCapture(
            makeFrame(at: 1, displayID: displayID, hash: 3),
            jpegData: Data(repeating: 2, count: 16)
        )
        let laterA = try await repository.recordEncodedCapture(
            makeFrame(at: 2, displayID: displayID, hash: 1),
            jpegData: aJPEG
        )

        XCTAssertEqual(droppedB.outcome.disposition, .pressureDrop)
        XCTAssertEqual(laterA.outcome.disposition, .pressureDrop)
        let timeline = await repository.orderedTimeline()
        XCTAssertEqual(timeline.count, 1)
        XCTAssertEqual(timeline.first?.frame.id, firstA.id)
        XCTAssertEqual(timeline.first?.span.observationCount, 1)
        XCTAssertEqual(timeline.first?.span.observedThroughAt, firstA.timestamp)
    }

    func testLeasedPayloadPreventsEvictionAndForcesDurableSpill() async throws {
        let store = try FrameStore(directory: directory)
        let repository = HybridFrameRepository(frameStore: store, byteCap: 16)
        let displayID = UUID()
        let startedAt = Date(timeIntervalSince1970: 10)
        _ = try await repository.beginCaptureSession(at: startedAt)

        let volatile = makeFrame(at: 11, displayID: displayID)
        let volatileResult = try await repository.recordEncodedCapture(
            volatile,
            jpegData: Data(repeating: 1, count: 16)
        )
        let lease = await repository.acquirePayloadLease(for: [volatile.id])
        let spill = makeFrame(at: 12, displayID: displayID)
        let spillResult = try await repository.recordEncodedCapture(
            spill,
            jpegData: Data(repeating: 2, count: 16)
        )
        _ = await lease.release()

        XCTAssertEqual(volatileResult.outcome.disposition, .durableFrame)
        XCTAssertEqual(spillResult.outcome.disposition, .durableFrame)
        XCTAssertEqual(anchorReason(in: spillResult.effects), .capacitySpill)
        let statistics = await repository.storageStatistics()
        let durableJPEGPayloadBytes = await repository.durableJPEGPayloadBytes()
        XCTAssertEqual(statistics.volatileBytes, 16)
        XCTAssertEqual(statistics.frameCount, 2)
        XCTAssertEqual(statistics.durableFrameCount, 2)
        XCTAssertEqual(statistics.volatileFrameCount, 1)
        XCTAssertGreaterThan(durableJPEGPayloadBytes, 0)
    }

    func testExactRingOnlySpanPromotesSameIdentityAndFullCoverageAtFiveSeconds() async throws {
        let store = try FrameStore(directory: directory)
        let repository = HybridFrameRepository(frameStore: store, byteCap: 1_000_000)
        let source: any FrameRepository = repository
        let displayID = UUID()
        let initial = Date(timeIntervalSince1970: 100)
        let admissionMode = await source.captureAdmissionMode()
        XCTAssertEqual(admissionMode, .hybridEveryCapture)
        _ = try await source.beginCaptureSession(at: initial)
        let jpeg = try makeJPEG(seed: 1)

        let anchor = makeFrame(at: 100, displayID: displayID)
        _ = try await source.recordEncodedCapture(anchor, jpegData: Data([9]))
        let first = makeFrame(at: 101, displayID: displayID)
        let second = makeFrame(at: 105, displayID: displayID)
        let firstResult = try await source.recordEncodedCapture(first, jpegData: jpeg)
        let secondResult = try await source.recordEncodedCapture(second, jpegData: jpeg)

        guard case .inserted(let inserted) = firstResult.mutation,
              case .extended(let extended) = secondResult.mutation else {
            return XCTFail("Expected an insert followed by an exact-byte extension")
        }
        XCTAssertEqual(secondResult.outcome.disposition, .durableFrame)
        XCTAssertEqual(extended.id, inserted.span.id)
        XCTAssertEqual(extended.observationCount, 2)
        XCTAssertEqual(extended.observedThroughAt, second.timestamp)

        let statistics = await repository.storageStatistics()
        XCTAssertGreaterThan(statistics.durableJPEGPayloadBytes, 0)
        XCTAssertEqual(statistics.frameCount, 2)
        XCTAssertEqual(statistics.durableFrameCount, 2)
        XCTAssertEqual(statistics.volatileBytes, Int64(jpeg.count + 1))
        XCTAssertEqual(statistics.volatileFrameCount, 2)
        XCTAssertEqual(statistics.volatileTimelineSpanCount, 2)
        XCTAssertEqual(statistics.volatileObservationCount, 3)
        XCTAssertEqual(statistics.volatileCoverageStart, anchor.timestamp)
        XCTAssertEqual(statistics.volatileCoverageEnd, second.timestamp)
    }

    func testVolatilePayloadResolvesAndExportsOriginalEncodedBytes() async throws {
        let store = try FrameStore(directory: directory, screenshotsDirectory: exportDirectory)
        let repository = HybridFrameRepository(frameStore: store, byteCap: 1_000_000)
        let source: any FrameRepository = repository
        let timestamp = Date(timeIntervalSince1970: 200)
        _ = try await source.beginCaptureSession(at: timestamp)
        let image = try makeImage(seed: 3)
        let jpeg = try XCTUnwrap(ImageEncoder.jpegData(from: image, quality: 0.79))
        let anchor = makeFrame(at: 200, displayID: UUID())
        _ = try await source.recordEncodedCapture(anchor, jpegData: Data([1]))
        let frame = makeFrame(at: 201, displayID: anchor.displayID)
        _ = try await source.recordEncodedCapture(frame, jpegData: jpeg)

        let full = try await source.loadFullImage(id: frame.id)
        let thumbnail = await source.loadThumbnail(id: frame.id)
        let search = try await source.loadSearchIndexImage(id: frame.id, maxPixelSize: 12)
        let exported = try await source.exportFrame(id: frame.id, timestamp: timestamp)

        XCTAssertEqual(full.width, image.width)
        XCTAssertEqual(thumbnail?.width, image.width)
        XCTAssertLessThanOrEqual(max(search.width, search.height), 12)
        XCTAssertEqual(try Data(contentsOf: exported), jpeg)
        let statistics = await repository.storageStatistics()
        let resolutionStatistics = await source.payloadResolutionStatistics()
        XCTAssertGreaterThan(statistics.durableJPEGPayloadBytes, 0)
        XCTAssertEqual(resolutionStatistics.volatilePayloadResolutions, 4)
        XCTAssertEqual(resolutionStatistics.durablePayloadResolutions, 0)
    }

    func testVolatileThenSpillDoesNotExtendOlderDurableSpanAfterVolatileEviction() async throws {
        let store = try FrameStore(directory: directory)
        let repository = HybridFrameRepository(frameStore: store, byteCap: 16)
        let displayOne = UUID()
        let displayTwo = UUID()
        let startedAt = Date(timeIntervalSince1970: 300)
        _ = try await repository.beginCaptureSession(at: startedAt)

        let oldDurable = makeFrame(at: 300, displayID: displayOne)
        let volatileOnDisplayOne = makeFrame(at: 301, displayID: displayOne)
        let evictionOnOtherDisplay = makeFrame(at: 302, displayID: displayTwo)
        let laterSpill = makeFrame(at: 303, displayID: displayOne)

        let first = try await repository.recordEncodedCapture(
            oldDurable,
            jpegData: Data(repeating: 1, count: 17)
        )
        _ = try await repository.recordEncodedCapture(
            volatileOnDisplayOne,
            jpegData: Data(repeating: 2, count: 16)
        )
        _ = try await repository.recordEncodedCapture(
            evictionOnOtherDisplay,
            jpegData: Data(repeating: 3, count: 16)
        )
        let spill = try await repository.recordEncodedCapture(
            laterSpill,
            jpegData: Data(repeating: 4, count: 17)
        )

        guard case .inserted(let originalSpan) = first.mutation,
              case .inserted(let spilledSpan) = spill.mutation else {
            return XCTFail("The later durable spill must start a new logical span")
        }
        XCTAssertEqual(spill.outcome.disposition, .durableFrame)
        XCTAssertNotEqual(spilledSpan.span.id, originalSpan.span.id)
        XCTAssertEqual(spilledSpan.span.frameID, laterSpill.id)

        let timeline = await repository.orderedTimeline()
        XCTAssertEqual(timeline.map(\.frame.id), [oldDurable.id, evictionOnOtherDisplay.id, laterSpill.id])
        XCTAssertFalse(timeline.contains { $0.span.id == originalSpan.span.id && $0.span.observationCount > 1 })
    }

    func testPruningActiveDurableSpanForcesFreshSpanForEarlierExactPayload() async throws {
        let store = try FrameStore(directory: directory)
        let repository = HybridFrameRepository(frameStore: store, byteCap: 4)
        let displayID = UUID()
        let startedAt = Date(timeIntervalSince1970: 350)
        _ = try await repository.beginCaptureSession(at: startedAt)
        let x = Data(repeating: 1, count: 8)
        let y = Data(repeating: 2, count: 8)

        let first = makeFrame(at: 351, displayID: displayID)
        let active = makeFrame(at: 352, displayID: displayID)
        let laterExactFirst = makeFrame(at: 353, displayID: displayID)
        let firstResult = try await repository.recordEncodedCapture(first, jpegData: x)
        let activeResult = try await repository.recordEncodedCapture(active, jpegData: y)
        guard case .inserted(let firstEntry) = firstResult.mutation,
              case .inserted(let activeEntry) = activeResult.mutation else {
            return XCTFail("Expected two durable inserts")
        }

        _ = try await repository.pruneSpans(ids: [activeEntry.span.id])
        let laterResult = try await repository.recordEncodedCapture(laterExactFirst, jpegData: x)
        guard case .inserted(let laterEntry) = laterResult.mutation else {
            return XCTFail("The post-prune exact payload must start a fresh span")
        }

        XCTAssertNotEqual(laterEntry.span.id, firstEntry.span.id)
        XCTAssertEqual(laterEntry.frame.id, laterExactFirst.id)
        let timeline = await repository.orderedTimeline()
        XCTAssertEqual(timeline.map(\.frame.id), [first.id, laterExactFirst.id])
        XCTAssertEqual(timeline.map(\.span.observationCount), [1, 1])
    }

    func testMissingDurableOnlyActivePayloadIsInvalidatedBeforeFreshCapture() async throws {
        let store = try FrameStore(directory: directory)
        let repository = HybridFrameRepository(frameStore: store, byteCap: 4)
        let displayID = UUID()
        let startedAt = Date(timeIntervalSince1970: 360)
        _ = try await repository.beginCaptureSession(at: startedAt)
        let jpeg = Data(repeating: 9, count: 8)
        let missing = makeFrame(at: 361, displayID: displayID)
        let fresh = makeFrame(at: 362, displayID: displayID)

        let initial = try await repository.recordEncodedCapture(missing, jpegData: jpeg)
        guard case .inserted(let missingEntry) = initial.mutation else {
            return XCTFail("Expected the oversized first capture to be durable-only")
        }
        try FileManager.default.removeItem(
            at: directory
                .appendingPathComponent("frames", isDirectory: true)
                .appendingPathComponent("\(missing.id.uuidString).jpg")
        )

        let recovered = try await repository.recordEncodedCapture(fresh, jpegData: jpeg)
        guard case .inserted(let freshEntry) = recovered.mutation else {
            return XCTFail("A missing durable payload must not wedge the fresh capture")
        }

        XCTAssertNotEqual(freshEntry.span.id, missingEntry.span.id)
        XCTAssertEqual(recovered.effects.invalidation.spanIDs, [missingEntry.span.id])
        XCTAssertEqual(recovered.effects.invalidation.finalPhysicalFrameIDs, [missing.id])
        let timeline = await repository.orderedTimeline()
        XCTAssertEqual(timeline.map(\.frame.id), [fresh.id])
        let metadata = await store.getAllMetadata()
        XCTAssertEqual(metadata.map(\.id), [fresh.id])
    }

    func testCurrentTimelineLeaseIncludesEveryVolatileDisplay() async throws {
        let store = try FrameStore(directory: directory)
        let durable = HybridDurableRepositoryProbe(
            base: DiskFrameRepository(frameStore: store)
        )
        let repository = HybridFrameRepository(durableRepository: durable, byteCap: 16)
        let startedAt = Date(timeIntervalSince1970: 400)
        _ = try await repository.beginCaptureSession(at: startedAt)
        let first = makeFrame(at: 400, displayID: UUID())
        let second = makeFrame(at: 401, displayID: UUID())
        _ = try await repository.recordEncodedCapture(first, jpegData: Data(repeating: 1, count: 8))
        _ = try await repository.recordEncodedCapture(second, jpegData: Data(repeating: 2, count: 8))

        await durable.suspendNextOrderedTimeline()
        let snapshotTask = Task {
            await repository.acquireCurrentTimelineSnapshotLease()
        }
        await durable.waitUntilOrderedTimelineRequested()
        let third = makeFrame(at: 402, displayID: UUID())
        let admissionTask = Task {
            try await repository.recordEncodedCapture(
                third,
                jpegData: Data(repeating: 3, count: 8)
            )
        }
        await durable.resumeOrderedTimeline()
        let leasedSnapshot = await snapshotTask.value
        XCTAssertEqual(Set(leasedSnapshot.entries.map(\.frame.id)), [first.id, second.id])
        let result = try await admissionTask.value
        _ = await leasedSnapshot.lease.release()

        XCTAssertEqual(result.outcome.disposition, .durableFrame)
        let statistics = await repository.storageStatistics()
        XCTAssertEqual(statistics.volatileFrameCount, 2)
    }

    func testPruneFailureRetainsAndResolvesVolatileTimeline() async throws {
        let store = try FrameStore(directory: directory)
        let durable = HybridDurableRepositoryProbe(
            base: DiskFrameRepository(frameStore: store)
        )
        let repository = HybridFrameRepository(durableRepository: durable, byteCap: 1_000_000)
        let startedAt = Date(timeIntervalSince1970: 450)
        _ = try await repository.beginCaptureSession(at: startedAt)
        let image = try makeImage(seed: 45)
        let jpeg = try XCTUnwrap(ImageEncoder.jpegData(from: image, quality: 0.8))
        let anchor = makeFrame(at: 450, displayID: UUID())
        _ = try await repository.recordEncodedCapture(anchor, jpegData: Data([1]))
        let frame = makeFrame(at: 451, displayID: anchor.displayID)
        let result = try await repository.recordEncodedCapture(frame, jpegData: jpeg)
        guard case .inserted(let entry) = result.mutation else {
            return XCTFail("Expected volatile insert")
        }
        await durable.failNextPrune()

        do {
            _ = try await repository.pruneSpans(ids: [entry.span.id])
            XCTFail("Expected injected durable prune failure")
        } catch HybridDurableRepositoryProbeError.injectedPruneFailure {
            // Expected.
        }

        let timeline = await repository.orderedTimeline()
        XCTAssertEqual(timeline.map(\.frame.id), [anchor.id, entry.frame.id])
        let resolved = try await repository.loadFullImage(id: frame.id)
        XCTAssertEqual(resolved.width, image.width)
        let statistics = await repository.storageStatistics()
        XCTAssertEqual(statistics.volatileFrameCount, 2)
    }

    func testClearFailureKeepsSessionAndRAMUsableForNextCapture() async throws {
        let store = try FrameStore(directory: directory)
        let durable = HybridDurableRepositoryProbe(
            base: DiskFrameRepository(frameStore: store)
        )
        let repository = HybridFrameRepository(durableRepository: durable, byteCap: 64)
        let startedAt = Date(timeIntervalSince1970: 470)
        _ = try await repository.beginCaptureSession(at: startedAt)
        let first = makeFrame(at: 471, displayID: UUID())
        _ = try await repository.recordEncodedCapture(first, jpegData: Data(repeating: 1, count: 16))
        await durable.failNextClear()

        do {
            try await repository.clear()
            XCTFail("Expected injected durable clear failure")
        } catch HybridDurableRepositoryProbeError.injectedClearFailure {
            // Expected.
        }

        let second = makeFrame(at: 472, displayID: first.displayID)
        _ = try await repository.recordEncodedCapture(second, jpegData: Data(repeating: 2, count: 16))
        let timeline = await repository.orderedTimeline()
        XCTAssertEqual(timeline.map(\.frame.id), [first.id, second.id])
    }

    func testConcurrentCapturesCannotExtendAcrossInterveningCapture() async throws {
        let store = try FrameStore(directory: directory)
        let durable = HybridDurableRepositoryProbe(
            base: DiskFrameRepository(frameStore: store)
        )
        let repository = HybridFrameRepository(durableRepository: durable, byteCap: 4)
        let displayID = UUID()
        let startedAt = Date(timeIntervalSince1970: 480)
        _ = try await repository.beginCaptureSession(at: startedAt)
        let first = makeFrame(at: 481, displayID: displayID)
        let intervening = makeFrame(at: 482, displayID: displayID)
        let laterExactFirst = makeFrame(at: 483, displayID: displayID)
        let firstData = Data(repeating: 1, count: 8)
        _ = try await repository.recordEncodedCapture(first, jpegData: firstData)

        await durable.suspendNextEncodedPayload()
        let interveningTask = Task {
            try await repository.recordEncodedCapture(
                intervening,
                jpegData: Data(repeating: 2, count: 8)
            )
        }
        await durable.waitUntilEncodedPayloadRequested()
        let laterTask = Task {
            try await repository.recordEncodedCapture(laterExactFirst, jpegData: firstData)
        }
        await durable.resumeEncodedPayload()
        _ = try await interveningTask.value
        _ = try await laterTask.value

        let timeline = await repository.orderedTimeline()
        XCTAssertEqual(timeline.map(\.frame.id), [first.id, intervening.id, laterExactFirst.id])
        XCTAssertEqual(timeline.map(\.span.observationCount), [1, 1, 1])
    }

    func testHybridRejectsPreSessionAndBackwardsPerDisplayObservations() async throws {
        let store = try FrameStore(directory: directory)
        let repository = HybridFrameRepository(frameStore: store, byteCap: 128)
        let firstDisplay = UUID()
        let secondDisplay = UUID()
        _ = try await repository.beginCaptureSession(at: Date(timeIntervalSince1970: 500))

        do {
            _ = try await repository.recordEncodedCapture(
                makeFrame(at: 499, displayID: firstDisplay),
                jpegData: Data([1])
            )
            XCTFail("Expected pre-session timestamp rejection")
        } catch FrameStoreError.staleCaptureObservation {
            // Expected.
        }

        let first = makeFrame(at: 502, displayID: firstDisplay)
        let independentDisplay = makeFrame(at: 501, displayID: secondDisplay)
        _ = try await repository.recordEncodedCapture(first, jpegData: Data([2]))
        _ = try await repository.recordEncodedCapture(independentDisplay, jpegData: Data([3]))

        do {
            _ = try await repository.recordEncodedCapture(
                makeFrame(at: 501.5, displayID: firstDisplay),
                jpegData: Data([4])
            )
            XCTFail("Expected backwards same-display timestamp rejection")
        } catch FrameStoreError.staleCaptureObservation {
            // Expected.
        }

        let timeline = await repository.orderedTimeline()
        XCTAssertEqual(timeline.map(\.frame.id), [independentDisplay.id, first.id])
    }

    func testEndingSessionKeepsRAMUntilClearButNewRepositoryHasNoRAMHistory() async throws {
        let store = try FrameStore(directory: directory)
        let repository = HybridFrameRepository(frameStore: store, byteCap: 64)
        let startedAt = Date(timeIntervalSince1970: 500)
        let session = try await repository.beginCaptureSession(at: startedAt)
        let anchor = makeFrame(at: 500, displayID: UUID())
        _ = try await repository.recordEncodedCapture(anchor, jpegData: Data(repeating: 8, count: 16))
        let frame = makeFrame(at: 501, displayID: anchor.displayID)
        _ = try await repository.recordEncodedCapture(frame, jpegData: Data(repeating: 9, count: 16))
        _ = try await repository.endCaptureSession(id: session.id, reason: .paused)

        let retainedTimeline = await repository.orderedTimeline()
        XCTAssertEqual(retainedTimeline.map(\.frame.id), [anchor.id, frame.id])
        let restartedRepository = HybridFrameRepository(frameStore: store, byteCap: 64)
        let restartedTimeline = await restartedRepository.orderedTimeline()
        XCTAssertEqual(restartedTimeline.map(\.frame.id), [anchor.id])

        try await repository.clear()
        let clearedTimeline = await repository.orderedTimeline()
        let clearedStatistics = await repository.storageStatistics()
        XCTAssertTrue(clearedTimeline.isEmpty)
        XCTAssertEqual(clearedStatistics.volatileBytes, 0)
    }

    func testPruningVolatileSpanReportsLogicalAndFinalPhysicalInvalidation() async throws {
        let store = try FrameStore(directory: directory)
        let repository = HybridFrameRepository(frameStore: store, byteCap: 64)
        let timestamp = Date(timeIntervalSince1970: 600)
        _ = try await repository.beginCaptureSession(at: timestamp)
        let anchor = makeFrame(at: 600, displayID: UUID())
        _ = try await repository.recordEncodedCapture(anchor, jpegData: Data([1]))
        let frame = makeFrame(at: 601, displayID: anchor.displayID)
        let result = try await repository.recordEncodedCapture(frame, jpegData: Data(repeating: 4, count: 16))
        guard case .inserted(let entry) = result.mutation else {
            return XCTFail("Expected a volatile insert")
        }

        let invalidation = try await repository.pruneSpans(ids: [entry.span.id])

        XCTAssertEqual(invalidation.spanIDs, [entry.span.id])
        XCTAssertEqual(invalidation.finalPhysicalFrameIDs, [entry.frame.id])
        let timeline = await repository.orderedTimeline()
        XCTAssertEqual(timeline.map(\.frame.id), [anchor.id])
    }

    func testPruningVolatileSpanUsesTargetedDurableReferenceLookup() async throws {
        let store = try FrameStore(directory: directory)
        let durable = HybridDurableRepositoryProbe(base: DiskFrameRepository(frameStore: store))
        let repository = HybridFrameRepository(durableRepository: durable, byteCap: 64)
        let timestamp = Date(timeIntervalSince1970: 610)
        _ = try await repository.beginCaptureSession(at: timestamp)
        let anchor = makeFrame(at: 610, displayID: UUID())
        _ = try await repository.recordEncodedCapture(anchor, jpegData: Data([1]))
        let volatile = makeFrame(at: 611, displayID: anchor.displayID)
        let result = try await repository.recordEncodedCapture(
            volatile,
            jpegData: Data(repeating: 4, count: 16)
        )
        guard case .inserted(let entry) = result.mutation else {
            return XCTFail("Expected a volatile insert")
        }
        let readsBefore = await durable.capturedStorageReadCounts()

        _ = try await repository.pruneSpans(ids: [entry.span.id])

        let readsAfter = await durable.capturedStorageReadCounts()
        XCTAssertEqual(readsAfter.orderedTimeline, readsBefore.orderedTimeline)
    }

    func testOrderedFramesKeepsPhysicalCaptureTimestampAfterSpanExtension() async throws {
        let store = try FrameStore(directory: directory)
        let repository = HybridFrameRepository(frameStore: store, byteCap: 64)
        let displayID = UUID()
        _ = try await repository.beginCaptureSession(at: Date(timeIntervalSince1970: 620))
        let first = makeFrame(at: 620, displayID: displayID)
        _ = try await repository.recordEncodedCapture(first, jpegData: Data([1]))
        let repeated = StoredFrame(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 625),
            hash: first.hash,
            displayID: displayID,
            displayName: "Renamed Display"
        )
        _ = try await repository.recordEncodedCapture(repeated, jpegData: Data([1]))

        let frames = await repository.orderedFrames()

        XCTAssertEqual(frames.map(\.id), [first.id])
        XCTAssertEqual(frames.first?.timestamp, first.timestamp)
    }

    func testPolicyUsesFirstMajorAndOrdinaryAnchorsWhileHashZeroNeverTriggersMajor() async throws {
        let store = try FrameStore(directory: directory)
        let repository = HybridFrameRepository(frameStore: store, byteCap: 1_000_000)
        let displayID = UUID()
        _ = try await repository.beginCaptureSession(at: Date(timeIntervalSince1970: 0))

        let first = try await repository.recordEncodedCapture(
            makeFrame(at: 0, displayID: displayID, hash: 1),
            jpegData: Data([1])
        )
        let major = try await repository.recordEncodedCapture(
            makeFrame(at: 1, displayID: displayID, hash: .max),
            jpegData: Data([2])
        )
        let zero = try await repository.recordEncodedCapture(
            makeFrame(at: 2, displayID: displayID, hash: 0),
            jpegData: Data([3])
        )
        let afterZero = try await repository.recordEncodedCapture(
            makeFrame(at: 3, displayID: displayID, hash: .max),
            jpegData: Data([4])
        )
        let ordinary = try await repository.recordEncodedCapture(
            makeFrame(at: 6, displayID: displayID, hash: .max),
            jpegData: Data([5])
        )

        XCTAssertEqual(anchorReason(in: first.effects), .firstInSession)
        XCTAssertEqual(anchorReason(in: major.effects), .majorChange)
        XCTAssertEqual(zero.outcome.disposition, .volatileFrame)
        XCTAssertEqual(afterZero.outcome.disposition, .volatileFrame)
        XCTAssertEqual(anchorReason(in: ordinary.effects), .ordinary)
    }

    func testMirroredExactDuplicatesCheckpointOnlyAfterThirtySeconds() async throws {
        let store = try FrameStore(directory: directory)
        let durable = HybridDurableRepositoryProbe(base: DiskFrameRepository(frameStore: store))
        let repository = HybridFrameRepository(durableRepository: durable, byteCap: 1_000_000)
        let displayID = UUID()
        let jpeg = Data([1, 2, 3])
        _ = try await repository.beginCaptureSession(at: Date(timeIntervalSince1970: 0))

        _ = try await repository.recordEncodedCapture(
            makeFrame(at: 0, displayID: displayID),
            jpegData: jpeg
        )
        _ = try await repository.recordEncodedCapture(
            makeFrame(at: 1, displayID: displayID),
            jpegData: jpeg
        )
        _ = try await repository.recordEncodedCapture(
            makeFrame(at: 29.999, displayID: displayID),
            jpegData: jpeg
        )
        var counts = await durable.capturedMutationCallCounts()
        XCTAssertEqual(counts.promoteVolatileEntry, 1)
        XCTAssertEqual(counts.checkpointPromotedSpan, 0)

        let checkpoint = try await repository.recordEncodedCapture(
            makeFrame(at: 30, displayID: displayID),
            jpegData: jpeg
        )
        counts = await durable.capturedMutationCallCounts()
        XCTAssertEqual(counts.checkpointPromotedSpan, 1)
        XCTAssertEqual(checkpoint.outcome.disposition, .spanCheckpoint)
        let timeline = await repository.orderedTimeline()
        XCTAssertEqual(timeline.first?.span.observationCount, 4)
    }

    func testTerminationPersistsOnlyLatestDifferingVolatileEntryPerDisplay() async throws {
        let store = try FrameStore(directory: directory)
        let repository = HybridFrameRepository(frameStore: store, byteCap: 1_000_000)
        let displayID = UUID()
        let session = try await repository.beginCaptureSession(at: Date(timeIntervalSince1970: 0))
        let anchor = makeFrame(at: 0, displayID: displayID)
        let earlierVolatile = makeFrame(at: 1, displayID: displayID)
        let latestVolatile = makeFrame(at: 2, displayID: displayID)
        _ = try await repository.recordEncodedCapture(anchor, jpegData: Data([1]))
        _ = try await repository.recordEncodedCapture(earlierVolatile, jpegData: Data([2]))
        _ = try await repository.recordEncodedCapture(latestVolatile, jpegData: Data([3]))

        let effects = try await repository.endCaptureSession(
            id: session.id,
            reason: .termination
        )
        XCTAssertEqual(anchorReason(in: effects), .termination)

        let restarted = HybridFrameRepository(frameStore: store, byteCap: 1_000_000)
        let durableIDs = Set((await restarted.orderedTimeline()).map(\.frame.id))
        XCTAssertEqual(durableIDs, [anchor.id, latestVolatile.id])
        XCTAssertFalse(durableIDs.contains(earlierVolatile.id))
    }

    func testCommittedPrefixEffectsSurviveLaterPromotionFailureWithoutRepeatingWrite() async throws {
        let store = try FrameStore(directory: directory)
        let durable = HybridDurableRepositoryProbe(base: DiskFrameRepository(frameStore: store))
        let repository = HybridFrameRepository(durableRepository: durable, byteCap: 8)
        let displayID = UUID()
        _ = try await repository.beginCaptureSession(at: Date(timeIntervalSince1970: 0))
        await durable.failPromotionCalls([2, 4])

        _ = try await repository.recordEncodedCapture(
            makeFrame(at: 0, displayID: displayID),
            jpegData: Data([1])
        )
        let volatile = try await repository.recordEncodedCapture(
            makeFrame(at: 1, displayID: displayID),
            jpegData: Data([2])
        )
        guard case .inserted(let volatileEntry) = volatile.mutation else {
            return XCTFail("Expected ring-only insertion")
        }

        do {
            _ = try await repository.recordEncodedCapture(
                makeFrame(at: 5, displayID: displayID),
                jpegData: Data([2])
            )
            XCTFail("Expected the first injected promotion failure")
        } catch HybridDurableRepositoryProbeError.injectedPromotionFailure {
            // Pending ring-only promotion retained.
        }

        let oversized = makeFrame(at: 6, displayID: displayID)
        do {
            _ = try await repository.recordEncodedCapture(
                oversized,
                jpegData: Data(repeating: 3, count: 9)
            )
            XCTFail("Expected the later capacity promotion failure")
        } catch HybridDurableRepositoryProbeError.injectedPromotionFailure {
            // The preceding promotion committed and its effects entered the outbox.
        }

        let recovered = try await repository.recordEncodedCapture(
            oversized,
            jpegData: Data(repeating: 3, count: 9)
        )
        XCTAssertTrue(recovered.effects.timelineUpserts.contains {
            $0.span.id == volatileEntry.span.id && $0.span.observationCount == 2
        })
        XCTAssertTrue(recovered.effects.timelineUpserts.contains { $0.frame.id == oversized.id })
        XCTAssertEqual(recovered.effects.newlyDurableEntries.count, 2)
        XCTAssertEqual(
            recovered.effects.persistenceEvents.filter {
                if case .durableAnchor = $0 { return true }
                return false
            }.count,
            2
        )
        XCTAssertEqual(
            recovered.effects.persistenceEvents.filter {
                if case .exactDuplicate = $0 { return true }
                return false
            }.count,
            1
        )
        let instrumentation = CapturePersistenceInstrumentation()
        // Replayed outbox effects do not carry the current capture's JPEG
        // context; the repository decision must still be counted exactly once.
        instrumentation.recordRepositoryEffects(recovered.effects)
        let snapshot = instrumentation.currentSnapshot()
        XCTAssertEqual(snapshot.duplicateRepositorySaves, 1)
        XCTAssertEqual(snapshot.repositoryExactDuplicateFrames, 1)
        let counts = await durable.capturedMutationCallCounts()
        XCTAssertEqual(counts.promoteVolatileEntry, 5)
    }

    func testPendingPromotionAdvancesClockBeforeQueuedCaptureIsRevalidated() async throws {
        let store = try FrameStore(directory: directory)
        let durable = HybridDurableRepositoryProbe(base: DiskFrameRepository(frameStore: store))
        let repository = HybridFrameRepository(durableRepository: durable, byteCap: 1_000)
        let displayID = UUID()
        _ = try await repository.beginCaptureSession(at: Date(timeIntervalSince1970: 0))
        await durable.failPromotionCalls([2])
        _ = try await repository.recordEncodedCapture(
            makeFrame(at: 0, displayID: displayID),
            jpegData: Data([1])
        )
        let pending = makeFrame(at: 10, displayID: displayID)
        do {
            _ = try await repository.recordEncodedCapture(pending, jpegData: Data([2]))
            XCTFail("Expected injected promotion failure")
        } catch HybridDurableRepositoryProbeError.injectedPromotionFailure {
            // Retained at t=10.
        }

        do {
            _ = try await repository.recordEncodedCapture(
                makeFrame(at: 5, displayID: displayID),
                jpegData: Data([3])
            )
            XCTFail("Expected queued stale capture rejection")
        } catch FrameStoreError.staleCaptureObservation {
            // The t=10 promotion committed before this revalidation.
        }

        let recovered = try await repository.recordEncodedCapture(
            makeFrame(at: 11, displayID: displayID),
            jpegData: Data([2])
        )
        XCTAssertTrue(recovered.effects.newlyDurableEntries.contains { $0.frame.id == pending.id })
        let timeline = await repository.orderedTimeline()
        XCTAssertEqual(timeline.map(\.span.observedThroughAt), [
            Date(timeIntervalSince1970: 0),
            Date(timeIntervalSince1970: 11),
        ])
        XCTAssertFalse(timeline.contains { $0.span.observedThroughAt == Date(timeIntervalSince1970: 5) })
    }

    func testNonTerminationCloseRetriesFirstAnchorAfterPostJPEGFailure() async throws {
        let instrumentation = CapturePersistenceInstrumentation()
        let store = try FrameStore(
            directory: directory,
            promotionPayloadDidWrite: { _ in
                throw HybridDurableRepositoryProbeError.injectedPromotionFailure
            }
        )
        let repository = HybridFrameRepository(frameStore: store, byteCap: 1_000)
        let session = try await repository.beginCaptureSession(at: Date(timeIntervalSince1970: 0))
        let frame = makeFrame(at: 1, displayID: UUID())
        let jpeg = Data([1, 2, 3, 4])

        do {
            _ = try await repository.recordEncodedCapture(frame, jpegData: jpeg)
            XCTFail("Expected post-JPEG promotion failure")
        } catch let failure as DurablePromotionFailure {
            instrumentation.recordPersistedJPEG(receipt: failure.writeReceipt)
        }

        let effects = try await repository.endCaptureSession(id: session.id, reason: .sleep)
        instrumentation.recordRepositoryEffects(effects)
        XCTAssertEqual(anchorReason(in: effects), .firstInSession)
        let snapshot = instrumentation.currentSnapshot()
        XCTAssertEqual(snapshot.persistedFrames, 1)
        XCTAssertEqual(snapshot.durableRepositorySaves, 1)
        XCTAssertEqual(snapshot.firstAnchorRepositorySaves, 1)
        XCTAssertEqual(snapshot.metadataTransactions, 1)

        let restarted = HybridFrameRepository(frameStore: store, byteCap: 1_000)
        let restartedFrames = await restarted.orderedFrames()
        XCTAssertEqual(restartedFrames.map(\.id), [frame.id])
    }

    func testTerminationCloseRetryReturnsEffectsOnceWithoutRepeatingPromotion() async throws {
        let store = try FrameStore(directory: directory)
        let durable = HybridDurableRepositoryProbe(base: DiskFrameRepository(frameStore: store))
        let repository = HybridFrameRepository(durableRepository: durable, byteCap: 1_000)
        let displayID = UUID()
        let session = try await repository.beginCaptureSession(at: Date(timeIntervalSince1970: 0))
        _ = try await repository.recordEncodedCapture(
            makeFrame(at: 0, displayID: displayID),
            jpegData: Data([1])
        )
        let tail = makeFrame(at: 1, displayID: displayID)
        _ = try await repository.recordEncodedCapture(tail, jpegData: Data([2]))
        await durable.failNextEnd()

        do {
            _ = try await repository.endCaptureSession(id: session.id, reason: .termination)
            XCTFail("Expected injected close failure")
        } catch HybridDurableRepositoryProbeError.injectedEndFailure {
            // The tail promotion committed, but no effects were delivered.
        }

        let effects = try await repository.endCaptureSession(
            id: session.id,
            reason: .termination
        )
        XCTAssertEqual(anchorReason(in: effects), .termination)
        XCTAssertEqual(effects.newlyDurableEntries.map(\.frame.id), [tail.id])
        let counts = await durable.capturedMutationCallCounts()
        XCTAssertEqual(counts.promoteVolatileEntry, 2)
    }

    func testFailedTerminationThenPruneThenRetryCannotResurrectTail() async throws {
        let store = try FrameStore(directory: directory)
        let durable = HybridDurableRepositoryProbe(base: DiskFrameRepository(frameStore: store))
        let repository = HybridFrameRepository(durableRepository: durable, byteCap: 1_000)
        let displayID = UUID()
        let session = try await repository.beginCaptureSession(at: Date(timeIntervalSince1970: 0))
        _ = try await repository.recordEncodedCapture(
            makeFrame(at: 0, displayID: displayID),
            jpegData: Data([1])
        )
        let tailResult = try await repository.recordEncodedCapture(
            makeFrame(at: 1, displayID: displayID),
            jpegData: Data([2])
        )
        guard case .inserted(let tailEntry) = tailResult.mutation else {
            return XCTFail("Expected a volatile tail")
        }
        await durable.failNextEnd()
        do {
            _ = try await repository.endCaptureSession(id: session.id, reason: .termination)
            XCTFail("Expected injected close failure")
        } catch HybridDurableRepositoryProbeError.injectedEndFailure {
            // Tail promotion committed and entered the session-end outbox.
        }

        _ = try await repository.pruneSpans(ids: [tailEntry.span.id])
        let retryEffects = try await repository.endCaptureSession(
            id: session.id,
            reason: .termination
        )

        XCTAssertFalse(retryEffects.timelineUpserts.contains { $0.span.id == tailEntry.span.id })
        XCTAssertFalse(retryEffects.newlyDurableEntries.contains { $0.span.id == tailEntry.span.id })
        let timelineAfterRetry = await repository.orderedTimeline()
        XCTAssertFalse(timelineAfterRetry.contains { $0.span.id == tailEntry.span.id })
    }

    func testConcurrentHybridStatisticsUseOneDurableSnapshotPerRequest() async throws {
        let store = try FrameStore(directory: directory)
        let durable = HybridDurableRepositoryProbe(base: DiskFrameRepository(frameStore: store))
        let repository = HybridFrameRepository(durableRepository: durable, byteCap: 1_000)
        _ = try await repository.beginCaptureSession(at: Date(timeIntervalSince1970: 0))
        _ = try await repository.recordEncodedCapture(
            makeFrame(at: 0, displayID: UUID()),
            jpegData: Data([1])
        )

        async let first = repository.storageStatistics()
        async let second = repository.storageStatistics()
        let values = await [first, second]
        let reads = await durable.capturedStorageReadCounts()

        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(reads.snapshot, 2)
        XCTAssertEqual(reads.orderedTimeline, 0)
    }

    private func makeFrame(
        at timestamp: TimeInterval,
        displayID: UUID?,
        hash: UInt64 = 42
    ) -> StoredFrame {
        StoredFrame(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: timestamp),
            hash: hash,
            displayID: displayID,
            displayName: "Test Display"
        )
    }

    private func anchorReason(
        in effects: FrameRepositoryEffects
    ) -> FrameRepositoryDurableAnchorReason? {
        for event in effects.persistenceEvents {
            if case .durableAnchor(reason: let reason, _, _, _, _, _) = event {
                return reason
            }
        }
        return nil
    }

    private func makeJPEG(seed: Int) throws -> Data {
        try XCTUnwrap(ImageEncoder.jpegData(from: makeImage(seed: seed), quality: 0.77))
    }

    private func makeImage(seed: Int) throws -> CGImage {
        try XCTUnwrap(
            TestImageFactory.makeImage(width: 32, height: 20) { x, y in
                (
                    UInt8((x * (seed + 7) + y * 11) % 256),
                    UInt8((x * 5 + y * (seed + 13)) % 256),
                    UInt8((x * 17 + y * 3 + seed) % 256)
                )
            }
        )
    }
}

enum HybridDurableRepositoryProbeError: Error {
    case injectedPruneFailure
    case injectedClearFailure
    case injectedPromotionFailure
    case injectedEndFailure
}

nonisolated struct HybridDurableMutationCallCounts: Equatable {
    var recordEncodedCapture = 0
    var promoteVolatileEntry = 0
    var checkpointPromotedSpan = 0
    var pruneSpans = 0
    var clear = 0

    static let zero = HybridDurableMutationCallCounts()
}

actor HybridDurableRepositoryProbe: HybridDurableRepository {
    private let base: DiskFrameRepository
    private var mutationCallCounts = HybridDurableMutationCallCounts.zero
    private var shouldFailNextPrune = false
    private var shouldFailNextClear = false
    private var promotionCallNumbersToFail: Set<Int> = []
    private var promotionCallNumber = 0
    private var shouldFailNextEnd = false
    private var shouldSuspendNextEncodedPayload = false
    private var encodedPayloadContinuation: CheckedContinuation<Void, Never>?
    private var encodedPayloadWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldSuspendNextOrderedTimeline = false
    private var orderedTimelineContinuation: CheckedContinuation<Void, Never>?
    private var orderedTimelineWaiters: [CheckedContinuation<Void, Never>] = []
    private var orderedTimelineCallCount = 0
    private var durableStorageSnapshotCallCount = 0

    init(base: DiskFrameRepository) {
        self.base = base
    }

    func captureAdmissionMode() async -> FrameCaptureAdmissionMode { .diskCadenceFiltered }
    func cleanupOrphans() async throws { try await base.cleanupOrphans() }
    func orderedFrames() async -> [StoredFrame] { await base.orderedFrames() }

    func orderedTimeline() async -> [TimelineEntry] {
        orderedTimelineCallCount += 1
        if shouldSuspendNextOrderedTimeline {
            shouldSuspendNextOrderedTimeline = false
            let waiters = orderedTimelineWaiters
            orderedTimelineWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                orderedTimelineContinuation = continuation
            }
        }
        return await base.orderedTimeline()
    }

    func beginCaptureSession(at startedAt: Date) async throws -> CaptureSession {
        try await base.beginCaptureSession(at: startedAt)
    }

    func endCaptureSession(
        id: UUID,
        reason: CaptureSessionEndReason
    ) async throws -> FrameRepositoryEffects {
        if shouldFailNextEnd {
            shouldFailNextEnd = false
            throw HybridDurableRepositoryProbeError.injectedEndFailure
        }
        return try await base.endCaptureSession(id: id, reason: reason)
    }

    func recordEncodedCapture(
        _ frame: StoredFrame,
        jpegData: Data
    ) async throws -> FrameRepositorySaveResult {
        mutationCallCounts.recordEncodedCapture += 1
        return try await base.recordEncodedCapture(frame, jpegData: jpegData)
    }

    func promoteVolatileEntry(
        _ entry: TimelineEntry,
        jpegData: Data
    ) async throws -> DurablePersistenceResult {
        mutationCallCounts.promoteVolatileEntry += 1
        promotionCallNumber += 1
        if promotionCallNumbersToFail.remove(promotionCallNumber) != nil {
            throw HybridDurableRepositoryProbeError.injectedPromotionFailure
        }
        return try await base.promoteVolatileEntry(entry, jpegData: jpegData)
    }

    func checkpointPromotedSpan(_ span: TimelineSpan) async throws -> DurablePersistenceResult {
        mutationCallCounts.checkpointPromotedSpan += 1
        return try await base.checkpointPromotedSpan(span)
    }

    func durableEntry(frameID: UUID, spanID: UUID) async throws -> TimelineEntry? {
        try await base.durableEntry(frameID: frameID, spanID: spanID)
    }

    func referencedFrameIDs(among frameIDs: Set<UUID>) async throws -> Set<UUID> {
        try await base.referencedFrameIDs(among: frameIDs)
    }

    func recordEncodedCapture(
        _ frame: StoredFrame,
        jpegData: Data,
        forceNewSpan: Bool
    ) async throws -> FrameRepositorySaveResult {
        mutationCallCounts.recordEncodedCapture += 1
        return try await base.recordEncodedCapture(
            frame,
            jpegData: jpegData,
            forceNewSpan: forceNewSpan
        )
    }

    func loadFullImage(id: UUID) async throws -> CGImage {
        try await base.loadFullImage(id: id)
    }

    func loadThumbnail(id: UUID) async -> CGImage? {
        await base.loadThumbnail(id: id)
    }

    func loadSearchIndexImage(id: UUID, maxPixelSize: Int) async throws -> CGImage {
        try await base.loadSearchIndexImage(id: id, maxPixelSize: maxPixelSize)
    }

    func exportFrame(id: UUID, timestamp: Date) async throws -> URL {
        try await base.exportFrame(id: id, timestamp: timestamp)
    }

    func exportCroppedImage(_ image: CGImage, timestamp: Date) async throws -> URL {
        try await base.exportCroppedImage(image, timestamp: timestamp)
    }

    func acquirePayloadLease(for physicalFrameIDs: Set<UUID>) async -> any FrameRepositoryPayloadLease {
        NoopFrameRepositoryPayloadLease()
    }

    func payloadResolutionStatistics() async -> FramePayloadResolutionStatistics { .empty }

    func pruneSpans(ids: Set<UUID>) async throws -> FrameRepositoryInvalidation {
        mutationCallCounts.pruneSpans += 1
        if shouldFailNextPrune {
            shouldFailNextPrune = false
            throw HybridDurableRepositoryProbeError.injectedPruneFailure
        }
        return try await base.pruneSpans(ids: ids)
    }

    func clear() async throws {
        mutationCallCounts.clear += 1
        if shouldFailNextClear {
            shouldFailNextClear = false
            throw HybridDurableRepositoryProbeError.injectedClearFailure
        }
        try await base.clear()
    }

    func durableJPEGPayloadBytes() async -> Int64 { await base.durableJPEGPayloadBytes() }
    func storageStatistics() async -> FrameStorageStatistics { await base.storageStatistics() }
    func durableStorageSnapshot(
        logicalOverlay: [TimelineEntry]
    ) async -> DurableFrameStorageSnapshot {
        durableStorageSnapshotCallCount += 1
        return await base.durableStorageSnapshot(logicalOverlay: logicalOverlay)
    }

    func capturedStorageReadCounts() -> (snapshot: Int, orderedTimeline: Int) {
        (durableStorageSnapshotCallCount, orderedTimelineCallCount)
    }
    func flush() async { await base.flush() }

    func encodedPayload(id: UUID) async throws -> Data {
        if shouldSuspendNextEncodedPayload {
            shouldSuspendNextEncodedPayload = false
            let waiters = encodedPayloadWaiters
            encodedPayloadWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                encodedPayloadContinuation = continuation
            }
        }
        return try await base.encodedPayload(id: id)
    }

    func exportEncodedPayload(_ data: Data, timestamp: Date) async throws -> URL {
        try await base.exportEncodedPayload(data, timestamp: timestamp)
    }

    func failNextPrune() { shouldFailNextPrune = true }
    func failNextClear() { shouldFailNextClear = true }
    func failNextEnd() { shouldFailNextEnd = true }
    func failPromotionCalls(_ callNumbers: Set<Int>) {
        promotionCallNumbersToFail = callNumbers
    }
    func resetMutationCallCounts() { mutationCallCounts = .zero }
    func capturedMutationCallCounts() -> HybridDurableMutationCallCounts { mutationCallCounts }
    func suspendNextEncodedPayload() { shouldSuspendNextEncodedPayload = true }
    func suspendNextOrderedTimeline() { shouldSuspendNextOrderedTimeline = true }

    func waitUntilEncodedPayloadRequested() async {
        guard encodedPayloadContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            encodedPayloadWaiters.append(continuation)
        }
    }

    func resumeEncodedPayload() {
        encodedPayloadContinuation?.resume()
        encodedPayloadContinuation = nil
    }

    func waitUntilOrderedTimelineRequested() async {
        guard orderedTimelineContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            orderedTimelineWaiters.append(continuation)
        }
    }

    func resumeOrderedTimeline() {
        orderedTimelineContinuation?.resume()
        orderedTimelineContinuation = nil
    }
}
