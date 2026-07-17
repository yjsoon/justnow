import CoreGraphics
import Foundation
import XCTest
@testable import JustNow

final class FrameStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testSaveAndLoadRoundTrip() async throws {
        let store = try FrameStore(directory: directory)
        let image = try makeImage()

        let metadata = try await store.saveFrame(
            image,
            timestamp: Date(timeIntervalSince1970: 1_000),
            hash: 42,
            displayID: nil,
            displayName: nil
        )

        let loaded = try await store.loadFullImage(id: metadata.id)
        XCTAssertEqual(loaded.width, image.width)
        XCTAssertEqual(loaded.height, image.height)

        let allMetadata = await store.getAllMetadata()
        XCTAssertEqual(allMetadata.map(\.id), [metadata.id])
        XCTAssertGreaterThan(metadata.fileSize, 0)

        let totalSize = await store.totalStorageSize()
        XCTAssertEqual(totalSize, metadata.fileSize)
    }

    func testLoadUnknownFrameThrowsFileNotFound() async throws {
        let store = try FrameStore(directory: directory)
        let unknownID = UUID()

        do {
            _ = try await store.loadFullImage(id: unknownID)
            XCTFail("Expected fileNotFound")
        } catch let FrameStoreError.fileNotFound(id) {
            XCTAssertEqual(id, unknownID)
        }
    }

    func testPruneRemovesMetadataAndFiles() async throws {
        let store = try FrameStore(directory: directory)
        let keep = try await store.saveFrame(
            makeImage(), timestamp: Date(), hash: 1, displayID: nil, displayName: nil
        )
        let drop = try await store.saveFrame(
            makeImage(), timestamp: Date(), hash: 2, displayID: nil, displayName: nil
        )

        try await store.pruneFrames(ids: [drop.id])

        let remaining = await store.getAllMetadata()
        XCTAssertEqual(remaining.map(\.id), [keep.id])

        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: framesDirectory.appendingPathComponent(drop.filename).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: framesDirectory.appendingPathComponent(keep.filename).path
            )
        )
    }

    func testManifestPersistsAcrossReinitialisation() async throws {
        let saved: FrameMetadata
        do {
            let store = try FrameStore(directory: directory)
            saved = try await store.saveFrame(
                makeImage(),
                timestamp: Date(timeIntervalSince1970: 2_000),
                hash: 7,
                displayID: UUID(),
                displayName: "Test Display"
            )
            await store.flushManifest()
        }

        let reopened = try FrameStore(directory: directory)
        let metadata = await reopened.getAllMetadata()

        XCTAssertEqual(metadata.map(\.id), [saved.id])
        XCTAssertEqual(metadata.first?.hash, 7)
        XCTAssertEqual(metadata.first?.displayName, "Test Display")
    }

    /// A corrupted manifest must not brick the store on every launch. It is
    /// quarantined together with the frames directory and the store starts
    /// empty, so the old JPEGs survive for manual recovery out of reach of
    /// orphan cleanup.
    func testCorruptedManifestIsQuarantinedInsteadOfFailingInit() async throws {
        let quarantinedFilename: String
        do {
            let store = try FrameStore(directory: directory)
            let metadata = try await store.saveFrame(
                makeImage(), timestamp: Date(), hash: 1, displayID: nil, displayName: nil
            )
            await store.flushManifest()
            quarantinedFilename = metadata.filename
        }

        let manifestURL = directory.appendingPathComponent("manifest.json")
        try Data("{not valid json".utf8).write(to: manifestURL)

        let store = try FrameStore(directory: directory)
        let metadata = await store.getAllMetadata()

        XCTAssertTrue(metadata.isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("manifest.json.corrupt").path
            )
        )

        let quarantinedFramePath = directory
            .appendingPathComponent("frames.corrupt", isDirectory: true)
            .appendingPathComponent(quarantinedFilename).path
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: quarantinedFramePath),
            "Pre-corruption JPEGs must move aside for manual recovery"
        )

        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: framesDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: framesDirectory.path), [])

        try await store.cleanupOrphans()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: quarantinedFramePath),
            "Orphan cleanup must never reach into the quarantine directory"
        )
    }

    /// The recovery guarantee must survive beyond the quarantine launch: once
    /// new captures repopulate the fresh manifest, a later launch's orphan
    /// cleanup must not reap the quarantined pre-corruption JPEGs.
    func testQuarantinedFramesSurviveCleanupAfterNewCapturesAreStored() async throws {
        let quarantinedFilename: String
        do {
            let store = try FrameStore(directory: directory)
            let metadata = try await store.saveFrame(
                makeImage(), timestamp: Date(), hash: 1, displayID: nil, displayName: nil
            )
            await store.flushManifest()
            quarantinedFilename = metadata.filename
        }

        try Data("{not valid json".utf8).write(
            to: directory.appendingPathComponent("manifest.json")
        )

        do {
            let store = try FrameStore(directory: directory)
            _ = try await store.saveFrame(
                makeImage(), timestamp: Date(), hash: 2, displayID: nil, displayName: nil
            )
            await store.flushManifest()
        }

        let reopened = try FrameStore(directory: directory)
        try await reopened.cleanupOrphans()

        let remaining = await reopened.getAllMetadata()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory
                    .appendingPathComponent("frames.corrupt", isDirectory: true)
                    .appendingPathComponent(quarantinedFilename).path
            ),
            "Quarantined JPEGs must survive cleanup on subsequent launches"
        )
    }

    /// Clear All History promises to delete every captured frame, so it must
    /// also remove any quarantined pre-corruption store, not just the active
    /// manifest and frames directory.
    func testClearRemovesQuarantinedStore() async throws {
        do {
            let store = try FrameStore(directory: directory)
            _ = try await store.saveFrame(
                makeImage(), timestamp: Date(), hash: 1, displayID: nil, displayName: nil
            )
            await store.flushManifest()
        }

        try Data("{not valid json".utf8).write(
            to: directory.appendingPathComponent("manifest.json")
        )

        let store = try FrameStore(directory: directory)
        let manifestQuarantinePath = directory.appendingPathComponent("manifest.json.corrupt").path
        let framesQuarantinePath = directory
            .appendingPathComponent("frames.corrupt", isDirectory: true).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestQuarantinePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: framesQuarantinePath))

        try await store.clear()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: manifestQuarantinePath),
            "Clearing history must delete the quarantined manifest"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: framesQuarantinePath),
            "Clearing history must delete the quarantined frames"
        )
    }

    /// A manifest that exists but cannot be read (permissions, I/O error)
    /// must take the same quarantine path as one that fails to decode,
    /// rather than bricking capture on every launch.
    func testUnreadableManifestIsQuarantinedInsteadOfFailingInit() async throws {
        try XCTSkipIf(geteuid() == 0, "Root bypasses POSIX permission checks")

        do {
            let store = try FrameStore(directory: directory)
            _ = try await store.saveFrame(
                makeImage(), timestamp: Date(), hash: 1, displayID: nil, displayName: nil
            )
            await store.flushManifest()
        }

        let manifestURL = directory.appendingPathComponent("manifest.json")
        let quarantineURL = directory.appendingPathComponent("manifest.json.corrupt")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: manifestURL.path
        )
        addTeardownBlock {
            for path in [manifestURL.path, quarantineURL.path]
            where FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o644], ofItemAtPath: path
                )
            }
        }

        let store = try FrameStore(directory: directory)
        let metadata = await store.getAllMetadata()

        XCTAssertTrue(metadata.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineURL.path))
    }

    func testCleanupOrphansRemovesUnknownFilesWhenManifestHasEntries() async throws {
        let store = try FrameStore(directory: directory)
        let metadata = try await store.saveFrame(
            makeImage(), timestamp: Date(), hash: 1, displayID: nil, displayName: nil
        )

        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        let strayURL = framesDirectory.appendingPathComponent("stray.jpg")
        try Data("stray".utf8).write(to: strayURL)

        try await store.cleanupOrphans()

        XCTAssertFalse(FileManager.default.fileExists(atPath: strayURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: framesDirectory.appendingPathComponent(metadata.filename).path
            )
        )
    }

    func testCleanupOrphansDropsManifestEntriesForMissingFiles() async throws {
        let store = try FrameStore(directory: directory)
        let metadata = try await store.saveFrame(
            makeImage(), timestamp: Date(), hash: 1, displayID: nil, displayName: nil
        )

        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.removeItem(
            at: framesDirectory.appendingPathComponent(metadata.filename)
        )

        try await store.cleanupOrphans()

        let remaining = await store.getAllMetadata()
        XCTAssertTrue(remaining.isEmpty)

        // The removed entry must also be unreachable through the ID index.
        do {
            _ = try await store.loadFullImage(id: metadata.id)
            XCTFail("Expected fileNotFound after cleanup")
        } catch FrameStoreError.fileNotFound {
        }
    }

    func testClearRemovesAllFramesAndFiles() async throws {
        let store = try FrameStore(directory: directory)
        _ = try await store.saveFrame(
            makeImage(), timestamp: Date(), hash: 1, displayID: nil, displayName: nil
        )
        _ = try await store.saveFrame(
            makeImage(), timestamp: Date(), hash: 2, displayID: nil, displayName: nil
        )

        try await store.clear()

        let metadata = await store.getAllMetadata()
        XCTAssertTrue(metadata.isEmpty)

        let totalSize = await store.totalStorageSize()
        XCTAssertEqual(totalSize, 0)

        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: framesDirectory.path)
        XCTAssertTrue(files.isEmpty)
    }

    func testThumbnailIsGeneratedLazilyAndCachedToDisk() async throws {
        let store = try FrameStore(directory: directory)
        let metadata = try await store.saveFrame(
            makeImage(width: 400, height: 300),
            timestamp: Date(),
            hash: 1,
            displayID: nil,
            displayName: nil
        )

        let thumbnail = await store.loadThumbnail(id: metadata.id)

        XCTAssertNotNil(thumbnail)
        XCTAssertLessThanOrEqual(
            max(thumbnail?.width ?? 0, thumbnail?.height ?? 0),
            Int(ImageEncoder.thumbnailMaxSize)
        )
        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: framesDirectory.appendingPathComponent(metadata.thumbnailFilename).path
            )
        )
    }

    private func makeImage(width: Int = 8, height: Int = 8) throws -> CGImage {
        try XCTUnwrap(
            TestImageFactory.makeImage(width: width, height: height) { x, y in
                (UInt8((x * 31) % 256), UInt8((y * 17) % 256), 128)
            }
        )
    }
}
