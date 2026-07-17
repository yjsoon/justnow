import CoreGraphics
import Foundation
import XCTest
@testable import JustNow

@MainActor
final class FrameBufferTests: XCTestCase {
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

    private func makeBuffer() async throws -> FrameBuffer {
        try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory
        )
    }

    func testStandardDuplicatePolicyMatchesDefaultCaptureInterval() {
        XCTAssertEqual(
            DuplicateFramePolicy.standard,
            .exact(atMostEvery: AppStorageDefault.captureInterval)
        )
    }

    func testAddFrameSyncStoresFrame() async throws {
        let buffer = try await makeBuffer()
        let image = try makeStructuredImage(seed: 1)

        await buffer.addFrameSync(image, timestamp: Date(), display: nil)

        XCTAssertEqual(buffer.frameCount, 1)
        XCTAssertEqual(buffer.getFrames().count, 1)
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
    }

    func testIdenticalFramesBeyondMinimumSpacingAreStored() async throws {
        let buffer = try await makeBuffer()
        let uniform = try XCTUnwrap(TestImageFactory.makeSolidImage(width: 32, height: 32, level: 40))
        let base = Date()

        await buffer.addFrameSync(uniform, timestamp: base, display: nil)
        await buffer.addFrameSync(uniform, timestamp: base.addingTimeInterval(1.0), display: nil)

        XCTAssertEqual(buffer.frameCount, 2)
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
        XCTAssertTrue(files.isEmpty)

        // The buffer must accept new captures after a clear.
        await buffer.addFrameSync(
            try makeStructuredImage(seed: 3),
            timestamp: base.addingTimeInterval(2),
            display: nil
        )
        XCTAssertEqual(buffer.frameCount, 1)
    }

    /// A sync capture racing a clear must neither deadlock nor land in the
    /// cleared history: addFrameSync retries after the clear finishes, so the
    /// frame is stored exactly once against the fresh buffer.
    func testClearDuringPendingSyncIngestRetriesAndStoresOnce() async throws {
        let buffer = try await makeBuffer()
        let image = try makeStructuredImage(seed: 1)

        let pendingCapture = Task {
            await buffer.addFrameSync(image, timestamp: Date(), display: nil)
        }
        try await buffer.clear()
        await pendingCapture.value

        XCTAssertEqual(buffer.frameCount, 1)
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
    }

    /// A corrupt manifest starts the buffer empty; the init-time text-cache
    /// prune must not treat that empty frame set as licence to wipe the whole
    /// OCR index.
    func testCorruptManifestDoesNotWipeTextCacheOnInit() async throws {
        let frameID: UUID
        do {
            let buffer = try await makeBuffer()
            await buffer.addFrameSync(try makeStructuredImage(seed: 1), timestamp: Date(), display: nil)
            let frame = try XCTUnwrap(buffer.getFrames().first)
            frameID = frame.id
            _ = await buffer.cacheOCRTextIfCurrent("hello world", for: frame)
            await buffer.flushCaches()
        }

        try Data("{not valid json".utf8).write(
            to: directory.appendingPathComponent("manifest.json")
        )

        let reopened = try await makeBuffer()

        XCTAssertEqual(reopened.frameCount, 0)
        let cachedCount = await reopened.textCache.count
        XCTAssertEqual(cachedCount, 1)
        let hasText = await reopened.textCache.hasCachedText(for: frameID)
        XCTAssertTrue(hasText)
    }

    /// Deterministic pattern per seed with strong structural differences so
    /// perceptual hashes are far apart between seeds.
    private func makeStructuredImage(seed: Int) throws -> CGImage {
        try XCTUnwrap(
            TestImageFactory.makeImage(width: 64, height: 64) { x, y in
                let band = ((x / 8) + seed) % 2 == 0
                let stripe = ((y / 8) &* (seed + 3)) % 3 == 0
                return band != stripe ? (240, 240, 240) : (10, 10, 10)
            }
        )
    }
}
