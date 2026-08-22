import CoreGraphics
import Foundation
import SQLite3
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

        let durableJPEGPayloadBytes = await store.durableJPEGPayloadBytes()
        XCTAssertEqual(durableJPEGPayloadBytes, metadata.fileSize)
    }

    func testStorageStatisticsAggregateManifestSnapshot() async throws {
        let store = try FrameStore(directory: directory)
        let firstDisplayID = UUID()
        let secondDisplayID = UUID()
        let first = try await store.saveFrame(
            makeImage(), timestamp: Date(), hash: 1,
            displayID: firstDisplayID, displayName: "Built-in Display"
        )
        let second = try await store.saveFrame(
            makeImage(), timestamp: Date(), hash: 2,
            displayID: secondDisplayID, displayName: "External Display"
        )
        let legacy = try await store.saveFrame(
            makeImage(), timestamp: Date(), hash: 3,
            displayID: nil, displayName: nil
        )

        let statistics = await store.storageStatistics()

        XCTAssertEqual(statistics.durableJPEGPayloadBytes, first.fileSize + second.fileSize + legacy.fileSize)
        XCTAssertGreaterThan(statistics.knownSQLiteAllocatedBytes, 0)
        XCTAssertGreaterThanOrEqual(statistics.sqliteWALAllocatedBytes, 0)
        XCTAssertLessThanOrEqual(
            statistics.sqliteWALAllocatedBytes,
            statistics.knownSQLiteAllocatedBytes
        )
        XCTAssertEqual(statistics.frameCount, 3)
        XCTAssertEqual(
            Set(statistics.projectionSamples.map(\.displayID)),
            Set<UUID?>([firstDisplayID, secondDisplayID, nil])
        )
        XCTAssertEqual(statistics.projectionSamples.reduce(0) { $0 + $1.frameCount }, 3)
    }

    func testStorageStatisticsIncludeAllocatedRollbackJournalSpace() async throws {
        let store = try FrameStore(directory: directory)
        let before = await store.storageStatistics()
        let journalURL = directory.appendingPathComponent("frames.sqlite-journal")
        try Data(repeating: 0xA5, count: 8_192).write(to: journalURL)

        let after = await store.storageStatistics()

        XCTAssertGreaterThan(after.knownSQLiteAllocatedBytes, before.knownSQLiteAllocatedBytes)
        XCTAssertEqual(after.sqliteWALAllocatedBytes, before.sqliteWALAllocatedBytes)
    }

    func testStorageStatisticsAggregatesDurableCoverageInSQL() async throws {
        let store = try FrameStore(directory: directory)
        let displayID = UUID()
        let session = try await store.beginCaptureSession(at: Date(timeIntervalSince1970: 0))
        let firstJPEG = try XCTUnwrap(
            ImageEncoder.jpegData(from: makeImage(width: 8, height: 8), quality: 0.8)
        )
        let secondJPEG = try XCTUnwrap(
            ImageEncoder.jpegData(from: makeImage(width: 12, height: 9), quality: 0.8)
        )
        let observations: [(TimeInterval, UInt64, Data)] = [
            (0, 1, firstJPEG),
            (2, 1, firstJPEG),
            (10, 2, secondJPEG),
            (13, 2, secondJPEG),
        ]
        for (timestamp, hash, jpeg) in observations {
            let frame = StoredFrame(
                id: UUID(),
                timestamp: Date(timeIntervalSince1970: timestamp),
                hash: hash,
                displayID: displayID,
                displayName: "Test Display"
            )
            _ = try await store.recordEncodedCapture(frame: frame, jpegData: jpeg)
        }

        let statistics = await store.storageStatistics()
        let coverage = try XCTUnwrap(
            statistics.displayCoverage.first { $0.displayID == displayID }
        )

        XCTAssertEqual(statistics.timelineSpanCount, 2)
        XCTAssertEqual(statistics.observationCount, 4)
        XCTAssertEqual(coverage.durable.oldest, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(coverage.durable.newest, Date(timeIntervalSince1970: 13))
        XCTAssertEqual(coverage.durable.coveredSeconds, 5, accuracy: 0.000_001)
        XCTAssertTrue(coverage.durable.hasGaps)
        XCTAssertEqual(coverage.combined, coverage.durable)

        let overlayFrame = StoredFrame(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 2),
            hash: 3,
            displayID: displayID,
            displayName: "Test Display"
        )
        let overlay = TimelineEntry(
            span: TimelineSpan(
                id: UUID(),
                frameID: overlayFrame.id,
                sessionID: session.id,
                startedAt: Date(timeIntervalSince1970: 2),
                observedThroughAt: Date(timeIntervalSince1970: 10),
                observationCount: 2,
                displayID: displayID,
                displayName: "Test Display"
            ),
            frame: overlayFrame
        )
        let combinedSnapshot = await store.storageSnapshot(logicalOverlay: [overlay])
        let combinedCoverage = try XCTUnwrap(
            combinedSnapshot.statistics.displayCoverage.first { $0.displayID == displayID }
        )
        XCTAssertEqual(combinedCoverage.durable.coveredSeconds, 5, accuracy: 0.000_001)
        XCTAssertTrue(combinedCoverage.durable.hasGaps)
        XCTAssertEqual(combinedCoverage.combined.coveredSeconds, 13, accuracy: 0.000_001)
        XCTAssertFalse(combinedCoverage.combined.hasGaps)
    }

    func testStorageStatisticsSamplesNewestFramesByTimestamp() async throws {
        let store = try FrameStore(directory: directory)
        let displayID = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_000)
        var expectedSampleBytes: Int64 = 0

        for offset in 1...50 {
            let metadata = try await store.saveFrame(
                makeImage(),
                timestamp: baseDate.addingTimeInterval(TimeInterval(offset)),
                hash: UInt64(offset),
                displayID: displayID,
                displayName: "Built-in Display"
            )
            expectedSampleBytes += metadata.fileSize
        }
        _ = try await store.saveFrame(
            makeImage(width: 400, height: 300),
            timestamp: baseDate,
            hash: 51,
            displayID: displayID,
            displayName: "Built-in Display"
        )

        let statistics = await store.storageStatistics()
        let sample = try XCTUnwrap(
            statistics.projectionSamples.first { $0.displayID == displayID }
        )

        XCTAssertEqual(sample.frameCount, 50)
        XCTAssertEqual(sample.jpegPayloadBytes, expectedSampleBytes)
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

    func testFailedMetadataInsertRollsBackNewJPEG() async throws {
        let store = try FrameStore(directory: directory)
        let databaseURL = directory.appendingPathComponent("frames.sqlite")
        try executeSQLite(databaseURL: databaseURL, sql: "DROP TABLE frames;")

        do {
            _ = try await store.saveFrame(
                makeImage(), timestamp: Date(), hash: 1, displayID: nil, displayName: nil
            )
            XCTFail("Expected database write failure")
        } catch FrameStoreError.database {
        }

        let frameFiles = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("frames", isDirectory: true),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent != ".store-id" }
        XCTAssertTrue(frameFiles.isEmpty)
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

    func testSQLiteMetadataPersistsAcrossReinitialisation() async throws {
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
            await store.flush()
        }

        let reopened = try FrameStore(directory: directory)
        let metadata = await reopened.getAllMetadata()

        XCTAssertEqual(metadata.map(\.id), [saved.id])
        XCTAssertEqual(metadata.first?.hash, 7)
        XCTAssertEqual(metadata.first?.displayName, "Test Display")
    }

    func testSQLitePreservesSubSecondTimestamps() async throws {
        let timestamp = Date(timeIntervalSince1970: 2_000.125)
        do {
            let store = try FrameStore(directory: directory)
            _ = try await store.saveFrame(
                makeImage(),
                timestamp: timestamp,
                hash: 7,
                displayID: nil,
                displayName: nil
            )
            await store.flush()
        }

        let reopened = try FrameStore(directory: directory)
        let persistedMetadata = await reopened.getAllMetadata()
        let persistedTimestamp = try XCTUnwrap(persistedMetadata.first?.timestamp)

        XCTAssertEqual(persistedTimestamp.timeIntervalSince1970, timestamp.timeIntervalSince1970, accuracy: 0.000_001)
    }

    func testSecondStoreRefusesLifetimeLockUntilFirstStoreIsReleased() throws {
        var firstStore: FrameStore? = try FrameStore(directory: directory)
        XCTAssertNotNil(firstStore)

        XCTAssertThrowsError(try FrameStore(directory: directory)) { error in
            guard case FrameStoreError.storeInUse = error else {
                return XCTFail("Expected storeInUse, got \(error)")
            }
        }

        firstStore = nil
        XCTAssertNoThrow(try FrameStore(directory: directory))
    }

    func testNewStoreDirectoryIsOwnerOnlyAndExcludedFromBackup() throws {
        _ = try FrameStore(directory: directory)

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue, 0o700)

        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testSymlinkedStorageRootIsRejectedWithoutTouchingExternalDirectory() throws {
        let externalDirectory = try makeExternalDirectory()
        let sentinelURL = externalDirectory.appendingPathComponent("sentinel.txt")
        try Data("unchanged".utf8).write(to: sentinelURL)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: externalDirectory)

        assertManagedSymlinkIsRejected(storageURL: directory)

        XCTAssertTrue(FrameStoreFile.isSymbolicLink(at: directory))
        XCTAssertEqual(try Data(contentsOf: sentinelURL), Data("unchanged".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: externalDirectory.path), ["sentinel.txt"])
    }

    func testSymlinkedFramesDirectoryIsRejectedWithoutTouchingExternalDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let externalDirectory = try makeExternalDirectory()
        let sentinelURL = externalDirectory.appendingPathComponent("sentinel.txt")
        try Data("unchanged".utf8).write(to: sentinelURL)
        let framesURL = directory.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: framesURL, withDestinationURL: externalDirectory)

        assertManagedSymlinkIsRejected(storageURL: directory)

        XCTAssertTrue(FrameStoreFile.isSymbolicLink(at: framesURL))
        XCTAssertEqual(try Data(contentsOf: sentinelURL), Data("unchanged".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: externalDirectory.path), ["sentinel.txt"])
        XCTAssertFalse(FrameStoreFile.exists(at: directory.appendingPathComponent(".store.lock")))
    }

    func testSymlinkedRecoveryDirectoryIsRejectedWithoutTouchingExternalDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let externalDirectory = try makeExternalDirectory()
        let sentinelURL = externalDirectory.appendingPathComponent("sentinel.txt")
        try Data("unchanged".utf8).write(to: sentinelURL)
        let recoveryURL = directory.appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: recoveryURL, withDestinationURL: externalDirectory)

        assertManagedSymlinkIsRejected(storageURL: directory)

        XCTAssertTrue(FrameStoreFile.isSymbolicLink(at: recoveryURL))
        XCTAssertEqual(try Data(contentsOf: sentinelURL), Data("unchanged".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: externalDirectory.path), ["sentinel.txt"])
        XCTAssertFalse(FrameStoreFile.exists(at: directory.appendingPathComponent(".store.lock")))
    }

    func testSymlinkedDatabaseIsRejectedWithoutReadingOrMovingExternalFile() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let externalURL = try makeExternalFile(contents: Data("external database sentinel".utf8))
        let databaseURL = directory.appendingPathComponent("frames.sqlite")
        try FileManager.default.createSymbolicLink(at: databaseURL, withDestinationURL: externalURL)

        assertManagedSymlinkIsRejected(storageURL: directory)

        XCTAssertTrue(FrameStoreFile.isSymbolicLink(at: databaseURL))
        XCTAssertEqual(try Data(contentsOf: externalURL), Data("external database sentinel".utf8))
        XCTAssertFalse(FrameStoreFile.exists(at: directory.appendingPathComponent(".store.lock")))
        XCTAssertFalse(FrameStoreFile.exists(at: directory.appendingPathComponent("recovery")))
    }

    func testSymlinkedManifestIsRejectedWithoutReadingOrMovingExternalFile() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let externalData = Data("external manifest sentinel".utf8)
        let externalURL = try makeExternalFile(contents: externalData)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try FileManager.default.createSymbolicLink(at: manifestURL, withDestinationURL: externalURL)

        assertManagedSymlinkIsRejected(storageURL: directory)

        XCTAssertTrue(FrameStoreFile.isSymbolicLink(at: manifestURL))
        XCTAssertEqual(try Data(contentsOf: externalURL), externalData)
        XCTAssertFalse(FrameStoreFile.exists(at: directory.appendingPathComponent(".store.lock")))
        XCTAssertFalse(FrameStoreFile.exists(at: directory.appendingPathComponent("frames.sqlite")))
        XCTAssertFalse(FrameStoreFile.exists(at: directory.appendingPathComponent("recovery")))
    }

    func testSymlinkedMigratedManifestIsRejectedWithoutReadingOrMovingExternalFile() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let externalData = Data("external migrated manifest sentinel".utf8)
        let externalURL = try makeExternalFile(contents: externalData)
        let manifestURL = directory.appendingPathComponent("manifest.json.migrated")
        try FileManager.default.createSymbolicLink(at: manifestURL, withDestinationURL: externalURL)

        assertManagedSymlinkIsRejected(storageURL: directory)

        XCTAssertTrue(FrameStoreFile.isSymbolicLink(at: manifestURL))
        XCTAssertEqual(try Data(contentsOf: externalURL), externalData)
        XCTAssertFalse(FrameStoreFile.exists(at: directory.appendingPathComponent(".store.lock")))
        XCTAssertFalse(FrameStoreFile.exists(at: directory.appendingPathComponent("frames.sqlite")))
    }

    func testMetadataLookupThrowsWhenSQLiteCannotExecuteQuery() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("frames.sqlite")
        let database = try FrameDatabase(url: databaseURL)
        defer { database.close() }

        try executeSQLite(databaseURL: databaseURL, sql: "DROP TABLE store_meta;")

        XCTAssertThrowsError(try database.metadataValue(for: "store_id"))
    }

    func testMigratesLegacyISO8601DatesAndRetainsBackup() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyTimestamp = Date(timeIntervalSince1970: 2_000)
        let legacyJPEG = try XCTUnwrap(
            ImageEncoder.jpegData(from: makeImage(), quality: 0.8)
        )
        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
        try legacyJPEG.write(to: framesDirectory.appendingPathComponent("legacy.jpg"))
        let legacyManifest = FrameManifest(
            frames: [
                FrameMetadata(
                    id: UUID(),
                    timestamp: legacyTimestamp,
                    hash: 7,
                    filename: "legacy.jpg",
                    thumbnailFilename: "legacy_thumb.jpg",
                    fileSize: Int64(legacyJPEG.count),
                    displayID: nil,
                    displayName: nil
                )
            ],
            lastModified: legacyTimestamp
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacyManifest).write(
            to: directory.appendingPathComponent("manifest.json")
        )

        let reopened = try FrameStore(directory: directory)
        let metadata = await reopened.getAllMetadata()

        XCTAssertEqual(metadata.first?.timestamp, legacyTimestamp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: FrameStore.migratedManifestURL(in: directory).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("frames.sqlite").path))
    }

    func testMigratesNumericLegacyDatesAndUInt64HashesExactlyOnce() async throws {
        let timestamp = Date(timeIntervalSince1970: 2_000.125)
        let hashes: [UInt64] = [0, UInt64(Int64.max) + 1, UInt64.max]
        let legacyJPEG = try XCTUnwrap(
            ImageEncoder.jpegData(from: makeImage(), quality: 0.8)
        )
        let frames = hashes.enumerated().map { offset, hash in
            let id = UUID()
            return FrameMetadata(
                id: id,
                timestamp: timestamp.addingTimeInterval(Double(offset)),
                hash: hash,
                filename: "\(id.uuidString).jpg",
                thumbnailFilename: "\(id.uuidString)_thumb.jpg",
                fileSize: Int64(legacyJPEG.count),
                displayID: nil,
                displayName: nil
            )
        }
        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
        for frame in frames {
            try legacyJPEG.write(
                to: framesDirectory.appendingPathComponent(frame.filename)
            )
        }
        try writeLegacyManifest(frames: frames, dateEncodingStrategy: .secondsSince1970)

        do {
            let store = try FrameStore(directory: directory)
            try await store.cleanupOrphans()
            let stored = await store.getAllMetadata()
            let storedHashes = stored.map(\.hash)
            XCTAssertEqual(storedHashes, hashes)
            XCTAssertEqual(stored.map(\.timestamp), frames.map(\.timestamp))
            XCTAssertEqual(stored.map(\.filename), frames.map(\.filename))
            XCTAssertEqual(stored.map(\.thumbnailFilename), frames.map(\.thumbnailFilename))
            XCTAssertEqual(stored.map(\.fileSize), frames.map(\.fileSize))
            for frame in frames {
                XCTAssertTrue(
                    FileManager.default.fileExists(
                        atPath: framesDirectory.appendingPathComponent(frame.filename).path
                    )
                )
            }
        }
        do {
            let reopened = try FrameStore(directory: directory)
            let storedIDs = await reopened.getAllMetadata().map(\.id)
            XCTAssertEqual(storedIDs, frames.map(\.id))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: FrameStore.migratedManifestURL(in: directory).path))
    }

    func testMigratedManifestBackupSurvivesOneLaterHealthyLaunch() async throws {
        let frame = try makeLegacyMetadata(hash: 7)
        try writeLegacyManifest(frames: [frame], dateEncodingStrategy: .secondsSince1970)

        do {
            _ = try FrameStore(directory: directory)
        }
        let backupURL = FrameStore.migratedManifestURL(in: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        do {
            _ = try FrameStore(directory: directory)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        do {
            _ = try FrameStore(directory: directory)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testInterruptedMigrationWithEmptyDatabaseResumesTransactionally() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("frames.sqlite")
        do {
            let partiallyInitialised = try FrameDatabase(url: databaseURL)
            partiallyInitialised.close()
        }
        let frame = try makeLegacyMetadata(hash: UInt64.max)
        try writeLegacyManifest(frames: [frame], dateEncodingStrategy: .secondsSince1970)

        let store = try FrameStore(directory: directory)
        let metadata = await store.getAllMetadata()

        XCTAssertEqual(metadata.map(\.id), [frame.id])
        XCTAssertEqual(metadata.map(\.hash), [UInt64.max])
        XCTAssertTrue(FileManager.default.fileExists(atPath: FrameStore.migratedManifestURL(in: directory).path))
    }

    func testCommittedMigrationWithUnrenamedManifestFinalisesWithoutDuplicates() async throws {
        let frame = try makeLegacyMetadata(hash: 99)
        try writeLegacyManifest(frames: [frame], dateEncodingStrategy: .secondsSince1970)
        do {
            _ = try FrameStore(directory: directory)
        }

        let backupURL = FrameStore.migratedManifestURL(in: directory)
        let originalURL = directory.appendingPathComponent("manifest.json")
        try FileManager.default.copyItem(at: backupURL, to: originalURL)

        let reopened = try FrameStore(directory: directory)
        let metadata = await reopened.getAllMetadata()

        XCTAssertEqual(metadata.map(\.id), [frame.id])
        XCTAssertEqual(metadata.first?.timestamp, frame.timestamp)
        XCTAssertEqual(metadata.first?.hash, frame.hash)
        XCTAssertEqual(metadata.first?.filename, frame.filename)
        XCTAssertEqual(metadata.first?.thumbnailFilename, frame.thumbnailFilename)
        XCTAssertEqual(metadata.first?.fileSize, frame.fileSize)
        XCTAssertEqual(metadata.first?.displayID, frame.displayID)
        XCTAssertEqual(metadata.first?.displayName, frame.displayName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testDatabaseUsesWALNormalSynchronousAndSchemaVersion() throws {
        let store = try FrameStore(directory: directory)
        _ = store

        let databaseURL = directory.appendingPathComponent("frames.sqlite")
        XCTAssertEqual(try sqliteText(databaseURL: databaseURL, sql: "PRAGMA journal_mode;"), "wal")
        XCTAssertEqual(try sqliteInt(databaseURL: databaseURL, sql: "PRAGMA user_version;"), 2)
        // synchronous is connection-local; opening FrameDatabase confirms the configured value.
        let database = try FrameDatabase(url: databaseURL)
        XCTAssertEqual(try database.configuredSynchronousMode(), 1)
        XCTAssertEqual(try database.configuredBusyTimeout(), 5_000)
        XCTAssertEqual(try sqliteInt(databaseURL: databaseURL, sql: "PRAGMA user_version;"), 2)
        database.close()
    }

    func testOwnedStoreMarkerMatchesDatabaseIdentity() throws {
        _ = try FrameStore(directory: directory)
        let markerValue = try String(
            contentsOf: FrameStore.ownedStoreMarkerURL(in: directory),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let databaseValue = try sqliteText(
            databaseURL: directory.appendingPathComponent("frames.sqlite"),
            sql: "SELECT value FROM store_meta WHERE key = 'store_id';"
        )

        XCTAssertFalse(markerValue.isEmpty)
        XCTAssertEqual(markerValue, databaseValue)
    }

    func testCorruptLegacyManifestAndJPEGMoveToUniqueRecoveryBundle() async throws {
        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
        try Data("recover me".utf8).write(to: framesDirectory.appendingPathComponent("legacy.jpg"))
        try Data("{not valid json".utf8).write(to: directory.appendingPathComponent("manifest.json"))

        do {
            let store = try FrameStore(directory: directory)
            let metadata = await store.getAllMetadata()
            XCTAssertTrue(metadata.isEmpty)
            XCTAssertTrue(recoveryContains(filename: "legacy.jpg"))
            XCTAssertTrue(recoveryContains(filename: "manifest.json"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: FrameStore.ownedStoreMarkerURL(in: directory).path))
        }

        let bundleCount = try recoveryBundleURLs().count
        let secondFramesDirectory = directory.appendingPathComponent("unidentified", isDirectory: true)
        try FileManager.default.createDirectory(at: secondFramesDirectory, withIntermediateDirectories: true)
        // A second recovery event must create a sibling, never overwrite the first.
        try Data("more".utf8).write(to: directory.appendingPathComponent("manifest.json"))
        _ = try FrameStore(directory: directory)
        XCTAssertGreaterThan(try recoveryBundleURLs().count, bundleCount)
    }

    func testCorruptDatabaseAndFramesMoveToRecoveryBeforeFreshStoreStarts() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
        try Data("recover me".utf8).write(to: framesDirectory.appendingPathComponent("preserved.jpg"))
        try Data("not a sqlite database".utf8).write(to: directory.appendingPathComponent("frames.sqlite"))
        let journalEvidence = Data("journal evidence".utf8)
        try journalEvidence.write(to: directory.appendingPathComponent("frames.sqlite-journal"))
        try Data("wal evidence".utf8).write(to: directory.appendingPathComponent("frames.sqlite-wal"))
        try Data("shm evidence".utf8).write(to: directory.appendingPathComponent("frames.sqlite-shm"))

        let store = try FrameStore(directory: directory)
        let metadata = await store.getAllMetadata()
        XCTAssertTrue(metadata.isEmpty)
        XCTAssertTrue(recoveryContains(filename: "frames.sqlite"))
        XCTAssertTrue(recoveryContains(filename: "frames.sqlite-journal"))
        XCTAssertTrue(recoveryContains(filename: "frames.sqlite-wal"))
        XCTAssertTrue(recoveryContains(filename: "frames.sqlite-shm"))
        XCTAssertTrue(recoveryContains(filename: "preserved.jpg"))
        let recoveredJournalURL = try XCTUnwrap(recoveryFileURL(filename: "frames.sqlite-journal"))
        XCTAssertEqual(try Data(contentsOf: recoveredJournalURL), journalEvidence)

        _ = try await store.saveFrame(
            makeImage(), timestamp: Date(), hash: 1, displayID: nil, displayName: nil
        )
        try await store.cleanupOrphans()
        XCTAssertTrue(recoveryContains(filename: "preserved.jpg"))
    }

    func testMalformedEmptyVersionOneSchemaIsRecovered() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("frames.sqlite")
        try executeSQLite(
            databaseURL: databaseURL,
            sql:
                """
                CREATE TABLE store_meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
                CREATE TABLE frames (wrong_column TEXT);
                PRAGMA user_version=1;
                """
        )
        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
        try Data("recover me".utf8).write(to: framesDirectory.appendingPathComponent("preserved.jpg"))

        let store = try FrameStore(directory: directory)
        let metadata = await store.getAllMetadata()

        XCTAssertTrue(metadata.isEmpty)
        XCTAssertTrue(recoveryContains(filename: "frames.sqlite"))
        XCTAssertTrue(recoveryContains(filename: "preserved.jpg"))
        XCTAssertEqual(try sqliteInt(databaseURL: databaseURL, sql: "PRAGMA user_version;"), 2)
    }

    func testSidecarsWithoutMainDatabaseAreRecoveredWithUnidentifiedFrames() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
        try Data("recover me".utf8).write(to: framesDirectory.appendingPathComponent("preserved.jpg"))
        try Data("orphan journal".utf8).write(to: directory.appendingPathComponent("frames.sqlite-journal"))
        try Data("orphan wal".utf8).write(to: directory.appendingPathComponent("frames.sqlite-wal"))
        try Data("orphan shm".utf8).write(to: directory.appendingPathComponent("frames.sqlite-shm"))

        _ = try FrameStore(directory: directory)

        XCTAssertTrue(recoveryContains(filename: "frames.sqlite-journal"))
        XCTAssertTrue(recoveryContains(filename: "frames.sqlite-wal"))
        XCTAssertTrue(recoveryContains(filename: "frames.sqlite-shm"))
        XCTAssertTrue(recoveryContains(filename: "preserved.jpg"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("frames.sqlite").path))
    }

    func testJPEGWithoutAnyMetadataIsRecoveredRatherThanDeleted() async throws {
        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
        try Data("recover me".utf8).write(to: framesDirectory.appendingPathComponent("unidentified.jpg"))

        _ = try FrameStore(directory: directory)

        XCTAssertTrue(recoveryContains(filename: "unidentified.jpg"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: framesDirectory.appendingPathComponent("unidentified.jpg").path))
    }

    func testUnsafeLegacyFilenameRecoversManifestWithoutEscapingFramesDirectory() async throws {
        let frame = FrameMetadata(
            id: UUID(),
            timestamp: Date(),
            hash: 1,
            filename: "../outside.jpg",
            thumbnailFilename: "safe_thumb.jpg",
            fileSize: 1,
            displayID: nil,
            displayName: nil
        )
        try writeLegacyManifest(frames: [frame], dateEncodingStrategy: .secondsSince1970)

        let store = try FrameStore(directory: directory)

        let metadata = await store.getAllMetadata()
        XCTAssertTrue(metadata.isEmpty)
        XCTAssertTrue(recoveryContains(filename: "manifest.json"))
    }

    func testReservedLegacyFilenameIsRejected() async throws {
        let frame = FrameMetadata(
            id: UUID(),
            timestamp: Date(),
            hash: 1,
            filename: "Frames.SQLite",
            thumbnailFilename: "safe_thumb.jpg",
            fileSize: 1,
            displayID: nil,
            displayName: nil
        )
        try writeLegacyManifest(frames: [frame], dateEncodingStrategy: .secondsSince1970)

        let store = try FrameStore(directory: directory)

        let metadata = await store.getAllMetadata()
        XCTAssertTrue(metadata.isEmpty)
        XCTAssertTrue(recoveryContains(filename: "manifest.json"))
    }

    func testLegacyManifestRejectsFullThumbnailCrossCollision() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let frames = [
            FrameMetadata(
                id: firstID,
                timestamp: Date(timeIntervalSince1970: 1),
                hash: 1,
                filename: "first.jpg",
                thumbnailFilename: "shared.jpg",
                fileSize: 1,
                displayID: nil,
                displayName: nil
            ),
            FrameMetadata(
                id: secondID,
                timestamp: Date(timeIntervalSince1970: 2),
                hash: 2,
                filename: "shared.jpg",
                thumbnailFilename: "second_thumb.jpg",
                fileSize: 1,
                displayID: nil,
                displayName: nil
            )
        ]
        try writeLegacyManifest(frames: frames, dateEncodingStrategy: .secondsSince1970)

        let store = try FrameStore(directory: directory)

        let metadata = await store.getAllMetadata()
        XCTAssertTrue(metadata.isEmpty)
        XCTAssertTrue(recoveryContains(filename: "manifest.json"))
    }

    func testDatabaseCrossColumnFilenameCollisionIsRecovered() async throws {
        let first: FrameMetadata
        let second: FrameMetadata
        do {
            let store = try FrameStore(directory: directory)
            first = try await store.saveFrame(
                makeImage(), timestamp: Date(timeIntervalSince1970: 1), hash: 1,
                displayID: nil, displayName: nil
            )
            second = try await store.saveFrame(
                makeImage(), timestamp: Date(timeIntervalSince1970: 2), hash: 2,
                displayID: nil, displayName: nil
            )
            await store.flush()
        }

        try executeSQLite(
            databaseURL: directory.appendingPathComponent("frames.sqlite"),
            sql:
                "UPDATE frames SET thumbnail_filename = '\(first.filename)' " +
                "WHERE id = '\(second.id.uuidString)';"
        )

        let reopened = try FrameStore(directory: directory)

        let metadata = await reopened.getAllMetadata()
        XCTAssertTrue(metadata.isEmpty)
        XCTAssertTrue(recoveryContains(filename: "frames.sqlite"))
        XCTAssertTrue(recoveryContains(filename: first.filename))
        XCTAssertTrue(recoveryContains(filename: second.filename))
    }

    func testDatabaseReservedPayloadFilenameIsRecovered() async throws {
        let saved: FrameMetadata
        do {
            let store = try FrameStore(directory: directory)
            saved = try await store.saveFrame(
                makeImage(), timestamp: Date(), hash: 1,
                displayID: nil, displayName: nil
            )
            await store.flush()
        }

        try executeSQLite(
            databaseURL: directory.appendingPathComponent("frames.sqlite"),
            sql:
                "UPDATE frames SET filename = 'Frames.SQLite' " +
                "WHERE id = '\(saved.id.uuidString)';"
        )

        let reopened = try FrameStore(directory: directory)

        let metadata = await reopened.getAllMetadata()
        XCTAssertTrue(metadata.isEmpty)
        XCTAssertTrue(recoveryContains(filename: "frames.sqlite"))
        XCTAssertTrue(recoveryContains(filename: saved.filename))
    }

    func testCleanupOrphansMovesUnknownFilesToRecovery() async throws {
        let store = try FrameStore(directory: directory)
        let metadata = try await store.saveFrame(
            makeImage(), timestamp: Date(), hash: 1, displayID: nil, displayName: nil
        )

        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        let strayURL = framesDirectory.appendingPathComponent("stray.jpg")
        try Data("stray".utf8).write(to: strayURL)

        try await store.cleanupOrphans()

        XCTAssertFalse(FileManager.default.fileExists(atPath: strayURL.path))
        XCTAssertTrue(recoveryContains(filename: "stray.jpg"))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: framesDirectory.appendingPathComponent(metadata.filename).path
            )
        )
    }

    func testOwnedEmptyStoreRecoversPostCrashOrphan() async throws {
        let store = try FrameStore(directory: directory)
        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        let orphanURL = framesDirectory.appendingPathComponent("post-crash.jpg")
        try Data("recover me".utf8).write(to: orphanURL)

        try await store.cleanupOrphans()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertTrue(recoveryContains(filename: "post-crash.jpg"))
        let metadata = await store.getAllMetadata()
        XCTAssertTrue(metadata.isEmpty)
    }

    func testCleanupIgnoresDirectoriesAndSymbolicLinks() async throws {
        let store = try FrameStore(directory: directory)
        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        let nestedDirectory = framesDirectory.appendingPathComponent("nested", isDirectory: true)
        let outsideFile = directory.appendingPathComponent("outside.jpg")
        let symlink = framesDirectory.appendingPathComponent("linked.jpg")
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outsideFile)
        let recoveryCount = try recoveryBundleURLs().count

        try await store.cleanupOrphans()

        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlink.path))
        XCTAssertEqual(try recoveryBundleURLs().count, recoveryCount)
    }

    func testCleanupOrphansDropsDatabaseRowsForMissingFiles() async throws {
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

        // The removed entry must also be unreachable through a direct DB lookup.
        do {
            _ = try await store.loadFullImage(id: metadata.id)
            XCTFail("Expected fileNotFound after cleanup")
        } catch FrameStoreError.fileNotFound {
        }
    }

    func testReferencedFullImageSymlinkIsNeverReadCopiedOrRetained() async throws {
        let store = try FrameStore(directory: directory)
        let metadata = try await store.saveFrame(
            makeImage(width: 16, height: 12),
            timestamp: Date(),
            hash: 1,
            displayID: nil,
            displayName: nil
        )
        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        let fullURL = framesDirectory.appendingPathComponent(metadata.filename)
        let externalURL = directory.appendingPathComponent("external.jpg")
        let externalData = try XCTUnwrap(
            ImageEncoder.jpegData(from: makeImage(width: 3, height: 2), quality: 0.8)
        )
        try externalData.write(to: externalURL)
        try FileManager.default.removeItem(at: fullURL)
        try FileManager.default.createSymbolicLink(at: fullURL, withDestinationURL: externalURL)

        for operation in [
            { try await store.loadFullImage(id: metadata.id) },
            { try await store.loadSearchIndexImage(id: metadata.id, maxPixelSize: 8) }
        ] {
            do {
                _ = try await operation()
                XCTFail("Expected fileNotFound for a symlinked frame payload")
            } catch FrameStoreError.fileNotFound {
            }
        }
        do {
            _ = try await store.copyFrameToScreenshotsLocation(
                id: metadata.id,
                timestamp: metadata.timestamp
            )
            XCTFail("Expected copy to reject a symlinked frame payload")
        } catch FrameStoreError.fileNotFound {
        }

        try await store.cleanupOrphans()

        let remainingMetadata = await store.getAllMetadata()
        XCTAssertTrue(remainingMetadata.isEmpty)
        XCTAssertEqual(try Data(contentsOf: externalURL), externalData)
        XCTAssertTrue(FrameStoreFile.exists(at: fullURL))
        XCTAssertFalse(FrameStoreFile.isRegularFile(at: fullURL))
    }

    func testSymlinkedThumbnailIsReplacedWithoutReadingExternalTarget() async throws {
        let store = try FrameStore(directory: directory)
        let metadata = try await store.saveFrame(
            makeImage(width: 400, height: 300),
            timestamp: Date(),
            hash: 1,
            displayID: nil,
            displayName: nil
        )
        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        let thumbnailURL = framesDirectory.appendingPathComponent(metadata.thumbnailFilename)
        let externalURL = directory.appendingPathComponent("external-thumbnail.jpg")
        let externalData = try XCTUnwrap(
            ImageEncoder.jpegData(from: makeImage(width: 2, height: 2), quality: 0.8)
        )
        try externalData.write(to: externalURL)
        try FileManager.default.createSymbolicLink(at: thumbnailURL, withDestinationURL: externalURL)

        let thumbnail = await store.loadThumbnail(id: metadata.id)

        XCTAssertEqual(thumbnail?.width, 200)
        XCTAssertEqual(thumbnail?.height, 150)
        XCTAssertTrue(FrameStoreFile.isRegularFile(at: thumbnailURL))
        XCTAssertEqual(try Data(contentsOf: externalURL), externalData)
    }

    func testClearRemovesAllFramesAndFiles() async throws {
        let store = try FrameStore(directory: directory)
        _ = try await store.saveFrame(
            makeImage(), timestamp: Date(), hash: 1, displayID: nil, displayName: nil
        )
        _ = try await store.saveFrame(
            makeImage(), timestamp: Date(), hash: 2, displayID: nil, displayName: nil
        )
        let recoveryBundle = FrameStore.recoveryDirectory(in: directory)
            .appendingPathComponent("manual-recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryBundle, withIntermediateDirectories: true)
        try Data("recovered frame".utf8).write(to: recoveryBundle.appendingPathComponent("old.jpg"))
        try Data("legacy backup".utf8).write(to: FrameStore.migratedManifestURL(in: directory))

        try await store.clear()

        let metadata = await store.getAllMetadata()
        XCTAssertTrue(metadata.isEmpty)

        let durableJPEGPayloadBytes = await store.durableJPEGPayloadBytes()
        XCTAssertEqual(durableJPEGPayloadBytes, 0)

        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: framesDirectory.path)
        XCTAssertEqual(files, [".store-id"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: FrameStore.recoveryDirectory(in: directory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: FrameStore.migratedManifestURL(in: directory).path))
    }

    func testClearReportsRetainedPayloadAndRetryEventuallyDeletesIt() async throws {
        let removal = ClearRemovalFailureProbe()
        let store = try FrameStore(
            directory: directory,
            clearPayloadRemoval: removal.remove
        )
        let oldMetadata = try await store.saveFrame(
            makeImage(), timestamp: Date(), hash: 1, displayID: nil, displayName: nil
        )
        let oldPayload = directory
            .appendingPathComponent("frames", isDirectory: true)
            .appendingPathComponent(oldMetadata.filename)

        do {
            try await store.clear()
            XCTFail("Expected clear to report retained payloads")
        } catch FrameStoreError.clearIncomplete(let paths) {
            let retainedPayloads = paths.map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
            }
            XCTAssertTrue(retainedPayloads.contains(oldPayload.resolvingSymlinksInPath().path))
        }

        let clearedMetadata = await store.getAllMetadata()
        XCTAssertTrue(clearedMetadata.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldPayload.path))

        removal.allowRemoval()
        try await store.clear()

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPayload.path))
        let startedAt = Date().addingTimeInterval(1)
        _ = try await store.beginCaptureSession(at: startedAt)
        let jpeg = try XCTUnwrap(ImageEncoder.jpegData(from: makeImage(), quality: 0.8))
        let nextFrame = StoredFrame(
            id: UUID(),
            timestamp: startedAt,
            hash: 2,
            displayID: nil,
            displayName: nil
        )
        _ = try await store.recordEncodedCapture(frame: nextFrame, jpegData: jpeg)
        let timeline = await store.getTimelineEntries()
        XCTAssertEqual(timeline.map(\.frame.id), [nextFrame.id])
    }

    func testClearIncompleteDescriptionBoundsAndRedactsPaths() {
        let paths = (0..<8).map {
            "/Users/private/Library/Application Support/JustNow/frame-\($0).jpg"
        }

        let description = FrameStoreError.clearIncomplete(paths).errorDescription

        XCTAssertNotNil(description)
        XCTAssertFalse(description?.contains("/Users/private") == true)
        XCTAssertTrue(description?.contains("frame-0.jpg") == true)
        XCTAssertFalse(description?.contains("frame-5.jpg") == true)
        XCTAssertTrue(description?.contains("and 3 more") == true)
    }

    func testStartupQuarantinesZeroLengthPayloadEvenWhenExpectedLengthIsZero() async throws {
        let metadata: FrameMetadata
        do {
            let store = try FrameStore(directory: directory)
            metadata = try await store.saveFrame(
                makeImage(), timestamp: Date(), hash: 1, displayID: nil, displayName: nil
            )
            await store.flush()
        }
        let payloadURL = framesDirectoryURL().appendingPathComponent(metadata.filename)
        try Data().write(to: payloadURL)
        try executeSQLite(
            databaseURL: directory.appendingPathComponent("frames.sqlite"),
            sql: "UPDATE frames SET file_size = 0 WHERE id = '\(metadata.id.uuidString)';"
        )

        let reopened = try FrameStore(directory: directory)

        let reopenedMetadata = await reopened.getAllMetadata()
        XCTAssertTrue(reopenedMetadata.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: payloadURL.path))
        XCTAssertTrue(recoveryContains(filename: metadata.filename))
    }

    func testStartupQuarantinesCorruptPayloadWithMatchingExpectedLength() async throws {
        let metadata: FrameMetadata
        do {
            let store = try FrameStore(directory: directory)
            metadata = try await store.saveFrame(
                makeImage(), timestamp: Date(), hash: 1, displayID: nil, displayName: nil
            )
            await store.flush()
        }
        let payloadURL = framesDirectoryURL().appendingPathComponent(metadata.filename)
        try Data(repeating: 0x41, count: Int(metadata.fileSize)).write(to: payloadURL)

        let reopened = try FrameStore(directory: directory)

        let reopenedMetadata = await reopened.getAllMetadata()
        XCTAssertTrue(reopenedMetadata.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: payloadURL.path))
        XCTAssertTrue(recoveryContains(filename: metadata.filename))
    }

    func testStartupQuarantinesTruncatedPayload() async throws {
        let metadata: FrameMetadata
        do {
            let store = try FrameStore(directory: directory)
            metadata = try await store.saveFrame(
                makeImage(), timestamp: Date(), hash: 1, displayID: nil, displayName: nil
            )
            await store.flush()
        }
        let payloadURL = framesDirectoryURL().appendingPathComponent(metadata.filename)
        let original = try Data(contentsOf: payloadURL)
        try original.prefix(max(1, original.count / 2)).write(to: payloadURL)

        let reopened = try FrameStore(directory: directory)

        let reopenedMetadata = await reopened.getAllMetadata()
        XCTAssertTrue(reopenedMetadata.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: payloadURL.path))
        XCTAssertTrue(recoveryContains(filename: metadata.filename))
    }

    func testStartupQuarantinesDecodablePayloadWithLengthMismatch() async throws {
        let metadata: FrameMetadata
        do {
            let store = try FrameStore(directory: directory)
            metadata = try await store.saveFrame(
                makeImage(), timestamp: Date(), hash: 1, displayID: nil, displayName: nil
            )
            await store.flush()
        }
        let payloadURL = framesDirectoryURL().appendingPathComponent(metadata.filename)
        var payload = try Data(contentsOf: payloadURL)
        payload.append(contentsOf: [0, 1, 2, 3])
        XCTAssertNotNil(ImageEncoder.cgImage(from: payload))
        try payload.write(to: payloadURL)

        let reopened = try FrameStore(directory: directory)

        let reopenedMetadata = await reopened.getAllMetadata()
        XCTAssertTrue(reopenedMetadata.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: payloadURL.path))
        XCTAssertTrue(recoveryContains(filename: metadata.filename))
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

    func testExactJPEGExtendsActiveSameDisplaySpanWithoutAnotherPayload() async throws {
        let store = try FrameStore(directory: directory)
        let displayID = UUID()
        let base = Date(timeIntervalSince1970: 10_000)
        let jpeg = try XCTUnwrap(ImageEncoder.jpegData(from: makeImage(width: 32, height: 24), quality: 0.8))
        _ = try await store.beginCaptureSession(at: base)
        let first = StoredFrame(
            id: UUID(), timestamp: base, hash: 1,
            displayID: displayID, displayName: "Display"
        )
        let second = StoredFrame(
            id: UUID(), timestamp: base.addingTimeInterval(5), hash: UInt64.max,
            displayID: displayID, displayName: "Renamed Display"
        )

        let inserted = try await store.recordEncodedCapture(frame: first, jpegData: jpeg)
        let extended = try await store.recordEncodedCapture(frame: second, jpegData: jpeg)

        guard case .inserted(let initialEntry) = inserted else {
            return XCTFail("Expected initial physical frame")
        }
        guard case .extended(let span) = extended else {
            return XCTFail("Expected exact bytes to extend the active span")
        }
        XCTAssertEqual(span.id, initialEntry.span.id)
        XCTAssertEqual(span.frameID, first.id)
        XCTAssertEqual(span.startedAt, base)
        XCTAssertEqual(span.observedThroughAt, second.timestamp)
        XCTAssertEqual(span.observationCount, 2)
        XCTAssertEqual(span.displayName, "Renamed Display")
        let metadata = await store.getAllMetadata()
        let timeline = await store.getTimelineEntries()
        XCTAssertEqual(metadata.map(\.id), [first.id])
        XCTAssertEqual(timeline.map(\.span), [span])
        let statistics = await store.storageStatistics()
        XCTAssertEqual(statistics.frameCount, 1)
        XCTAssertEqual(statistics.timelineSpanCount, 1)
        XCTAssertEqual(statistics.observationCount, 2)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("frames/\(second.id.uuidString).jpg").path
            )
        )
    }

    func testMissingActivePayloadFallsBackToFreshCapture() async throws {
        let store = try FrameStore(directory: directory)
        let base = Date(timeIntervalSince1970: 15_000)
        let jpeg = try XCTUnwrap(
            ImageEncoder.jpegData(from: makeImage(width: 32, height: 24), quality: 0.8)
        )
        _ = try await store.beginCaptureSession(at: base)
        let first = StoredFrame(
            id: UUID(), timestamp: base, hash: 1,
            displayID: nil, displayName: nil
        )
        let second = StoredFrame(
            id: UUID(), timestamp: base.addingTimeInterval(1), hash: 2,
            displayID: nil, displayName: nil
        )
        _ = try await store.recordEncodedCapture(frame: first, jpegData: jpeg)
        try FileManager.default.removeItem(
            at: framesDirectoryURL().appendingPathComponent("\(first.id.uuidString).jpg")
        )

        guard case .inserted(let entry) = try await store.recordEncodedCapture(
            frame: second,
            jpegData: jpeg
        ) else {
            return XCTFail("An unreadable comparison payload must not wedge capture")
        }

        XCTAssertEqual(entry.frame.id, second.id)
        let timeline = await store.getTimelineEntries()
        XCTAssertEqual(timeline.map(\.frame.id), [second.id])
        let metadata = await store.getAllMetadata()
        XCTAssertEqual(metadata.map(\.id), [second.id])
    }

    func testSamePerceptualHashWithDifferentJPEGBytesCreatesAnotherSpan() async throws {
        let store = try FrameStore(directory: directory)
        let base = Date(timeIntervalSince1970: 20_000)
        let firstJPEG = try XCTUnwrap(
            ImageEncoder.jpegData(from: makeImage(width: 24, height: 16), quality: 0.8)
        )
        let secondJPEG = try XCTUnwrap(
            ImageEncoder.jpegData(from: makeImage(width: 31, height: 19), quality: 0.8)
        )
        XCTAssertNotEqual(firstJPEG, secondJPEG)
        _ = try await store.beginCaptureSession(at: base)

        for (offset, jpeg) in [firstJPEG, secondJPEG].enumerated() {
            let frame = StoredFrame(
                id: UUID(),
                timestamp: base.addingTimeInterval(TimeInterval(offset + 1)),
                hash: 42,
                displayID: nil,
                displayName: nil
            )
            guard case .inserted = try await store.recordEncodedCapture(frame: frame, jpegData: jpeg) else {
                return XCTFail("Perceptual equality must not coalesce different bytes")
            }
        }

        let metadata = await store.getAllMetadata()
        let timeline = await store.getTimelineEntries()
        XCTAssertEqual(metadata.count, 2)
        XCTAssertEqual(timeline.count, 2)
    }

    func testExactJPEGLargerThanObserverBudgetStillExtendsSpan() async throws {
        let store = try FrameStore(directory: directory)
        let base = Date(timeIntervalSince1970: 30_000)
        let prefix = try XCTUnwrap(ImageEncoder.jpegData(from: makeImage(), quality: 0.8))
        let jpeg = prefix + Data(
            repeating: 0xA5,
            count: CapturePersistenceInstrumentation.maximumComparableJPEGBytes + 1
        )
        _ = try await store.beginCaptureSession(at: base)
        let first = StoredFrame(id: UUID(), timestamp: base, hash: 1, displayID: nil, displayName: nil)
        let second = StoredFrame(
            id: UUID(), timestamp: base.addingTimeInterval(5), hash: 2,
            displayID: nil, displayName: nil
        )

        _ = try await store.recordEncodedCapture(frame: first, jpegData: jpeg)
        guard case .extended(let span) = try await store.recordEncodedCapture(frame: second, jpegData: jpeg) else {
            return XCTFail("Exact comparison must not have an observer-size cap")
        }

        XCTAssertGreaterThan(jpeg.count, CapturePersistenceInstrumentation.maximumComparableJPEGBytes)
        XCTAssertEqual(span.observationCount, 2)
        let metadata = await store.getAllMetadata()
        XCTAssertEqual(metadata.count, 1)
    }

    func testSessionBoundaryNeverExtendsPriorSpanEvenForExactBytes() async throws {
        let store = try FrameStore(directory: directory)
        let base = Date(timeIntervalSince1970: 40_000)
        let jpeg = try XCTUnwrap(ImageEncoder.jpegData(from: makeImage(), quality: 0.8))
        _ = try await store.beginCaptureSession(at: base)
        let first = StoredFrame(id: UUID(), timestamp: base, hash: 1, displayID: nil, displayName: nil)
        _ = try await store.recordEncodedCapture(frame: first, jpegData: jpeg)
        try await store.endCaptureSession(reason: .paused)
        _ = try await store.beginCaptureSession(at: base.addingTimeInterval(10))
        let second = StoredFrame(
            id: UUID(), timestamp: base.addingTimeInterval(10), hash: 1,
            displayID: nil, displayName: nil
        )

        guard case .inserted = try await store.recordEncodedCapture(frame: second, jpegData: jpeg) else {
            return XCTFail("A new session must start a new span")
        }

        let metadata = await store.getAllMetadata()
        XCTAssertEqual(metadata.count, 2)
        let timeline = await store.getTimelineEntries()
        XCTAssertEqual(timeline.count, 2)
        XCTAssertNotEqual(timeline[0].span.sessionID, timeline[1].span.sessionID)
    }

    func testPreSessionCaptureIsRejectedAndEmptySessionEndIsClampedAcrossReopen() async throws {
        let base = Date(timeIntervalSince1970: 45_000)
        let jpeg = try XCTUnwrap(ImageEncoder.jpegData(from: makeImage(), quality: 0.8))
        let sessionID: UUID
        do {
            let store = try FrameStore(directory: directory)
            let session = try await store.beginCaptureSession(at: base)
            sessionID = session.id
            let staleFrame = StoredFrame(
                id: UUID(),
                timestamp: base.addingTimeInterval(-10),
                hash: 1,
                displayID: nil,
                displayName: nil
            )

            do {
                _ = try await store.recordEncodedCapture(frame: staleFrame, jpegData: jpeg)
                XCTFail("Expected a pre-session observation to be rejected")
            } catch FrameStoreError.staleCaptureObservation {
            }
            try await store.endCaptureSession(id: session.id, reason: .termination)
        }

        let reopened = try FrameStore(directory: directory)
        let sessions = await reopened.getCaptureSessions()
        let session = try XCTUnwrap(sessions.first { $0.id == sessionID })
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(session.endReason, .termination)
        XCTAssertEqual(
            try XCTUnwrap(session.endedAt).timeIntervalSince1970,
            base.timeIntervalSince1970,
            accuracy: 0.000_001
        )
        let metadata = await reopened.getAllMetadata()
        XCTAssertTrue(metadata.isEmpty)
    }

    func testBeginCaptureSessionRefusesToReuseAnOpenSession() async throws {
        let store = try FrameStore(directory: directory)
        let first = try await store.beginCaptureSession(at: Date(timeIntervalSince1970: 46_000))

        do {
            _ = try await store.beginCaptureSession(at: Date(timeIntervalSince1970: 46_010))
            XCTFail("Expected a second begin to fail while the first session is open")
        } catch FrameStoreError.database(let message) {
            XCTAssertTrue(message.contains(first.id.uuidString))
        }

        let sessions = await store.getCaptureSessions()
        XCTAssertEqual(sessions.map(\.id), [first.id])
        XCTAssertNil(sessions.first?.endedAt)
        try await store.endCaptureSession(id: first.id, reason: .termination)
    }

    func testNilAndNamedDisplaysMaintainIndependentExactByteSpans() async throws {
        let store = try FrameStore(directory: directory)
        let displayID = UUID()
        let base = Date(timeIntervalSince1970: 47_000)
        let jpeg = try XCTUnwrap(ImageEncoder.jpegData(from: makeImage(), quality: 0.8))
        _ = try await store.beginCaptureSession(at: base)

        let observations: [(TimeInterval, UUID?, String?)] = [
            (0, nil, nil),
            (1, displayID, "External"),
            (2, nil, nil),
            (3, displayID, "Renamed External")
        ]
        for (offset, capturedDisplayID, capturedDisplayName) in observations {
            let frame = StoredFrame(
                id: UUID(),
                timestamp: base.addingTimeInterval(offset),
                hash: UInt64(offset + 1),
                displayID: capturedDisplayID,
                displayName: capturedDisplayName
            )
            _ = try await store.recordEncodedCapture(frame: frame, jpegData: jpeg)
        }

        let metadata = await store.getAllMetadata()
        let timeline = await store.getTimelineEntries()
        XCTAssertEqual(metadata.count, 2)
        XCTAssertEqual(timeline.count, 2)
        XCTAssertEqual(timeline.map(\.span.observationCount), [2, 2])
        XCTAssertEqual(timeline.map(\.span.displayID), [nil, displayID])
        XCTAssertEqual(timeline.last?.span.displayName, "Renamed External")
    }

    func testReopenClosesInterruptedSessionAtLastCommittedObservation() async throws {
        let base = Date(timeIntervalSince1970: 50_000)
        let jpeg = try XCTUnwrap(ImageEncoder.jpegData(from: makeImage(), quality: 0.8))
        do {
            let store = try FrameStore(directory: directory)
            _ = try await store.beginCaptureSession(at: base)
            let first = StoredFrame(id: UUID(), timestamp: base, hash: 1, displayID: nil, displayName: nil)
            let second = StoredFrame(
                id: UUID(), timestamp: base.addingTimeInterval(12), hash: 2,
                displayID: nil, displayName: nil
            )
            _ = try await store.recordEncodedCapture(frame: first, jpegData: jpeg)
            _ = try await store.recordEncodedCapture(frame: second, jpegData: jpeg)
            await store.flush()
        }

        let reopened = try FrameStore(directory: directory)
        let reopenedSessions = await reopened.getCaptureSessions()
        XCTAssertEqual(reopenedSessions.count, 1)
        let prior = try XCTUnwrap(reopenedSessions.first)
        XCTAssertEqual(prior.endReason, .interrupted)
        XCTAssertEqual(
            try XCTUnwrap(prior.endedAt).timeIntervalSince1970,
            base.addingTimeInterval(12).timeIntervalSince1970,
            accuracy: 0.000_001
        )
        _ = try await reopened.beginCaptureSession(at: base.addingTimeInterval(100))
        let next = StoredFrame(
            id: UUID(), timestamp: base.addingTimeInterval(100), hash: 2,
            displayID: nil, displayName: nil
        )
        guard case .inserted = try await reopened.recordEncodedCapture(frame: next, jpegData: jpeg) else {
            return XCTFail("Restart must not bridge the interrupted session")
        }
        let metadata = await reopened.getAllMetadata()
        XCTAssertEqual(metadata.count, 2)
    }

    func testVersionOneDatabaseMigratesStableIDsFilesAndTimeline() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
        let frameID = UUID()
        let displayID = UUID()
        let filename = "\(frameID.uuidString).jpg"
        let thumbnailFilename = "\(frameID.uuidString)_thumb.jpg"
        let jpeg = try XCTUnwrap(
            ImageEncoder.jpegData(from: makeImage(), quality: 0.8)
        )
        try jpeg.write(to: framesDirectory.appendingPathComponent(filename))
        let databaseURL = directory.appendingPathComponent("frames.sqlite")
        try executeSQLite(
            databaseURL: databaseURL,
            sql:
                """
                CREATE TABLE store_meta (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                CREATE TABLE frames (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    captured_at REAL NOT NULL,
                    perceptual_hash BLOB NOT NULL CHECK(length(perceptual_hash) = 8),
                    filename TEXT NOT NULL UNIQUE,
                    thumbnail_filename TEXT NOT NULL UNIQUE,
                    file_size INTEGER NOT NULL CHECK(file_size >= 0),
                    display_id TEXT,
                    display_name TEXT
                );
                CREATE INDEX idx_frames_captured_at
                    ON frames(captured_at ASC, sequence ASC);
                CREATE INDEX idx_frames_display_captured_at
                    ON frames(display_id, captured_at DESC, sequence DESC);
                INSERT INTO frames (
                    id, captured_at, perceptual_hash, filename,
                    thumbnail_filename, file_size, display_id, display_name
                ) VALUES (
                    '\(frameID.uuidString)', 1234.5, X'2A00000000000000',
                    '\(filename)', '\(thumbnailFilename)', \(jpeg.count),
                    '\(displayID.uuidString)', 'Legacy Display'
                );
                PRAGMA user_version=1;
                """
        )

        do {
            let store = try FrameStore(directory: directory)
            let metadata = await store.getAllMetadata()
            let timeline = await store.getTimelineEntries()
            let sessions = await store.getCaptureSessions()

            XCTAssertEqual(try sqliteInt(databaseURL: databaseURL, sql: "PRAGMA user_version;"), 2)
            XCTAssertEqual(metadata.map(\.id), [frameID])
            XCTAssertEqual(metadata.first?.filename, filename)
            XCTAssertEqual(timeline.map(\.span.id), [frameID])
            XCTAssertEqual(timeline.map(\.span.frameID), [frameID])
            XCTAssertEqual(timeline.first?.span.startedAt.timeIntervalSince1970, 1234.5)
            XCTAssertEqual(timeline.first?.span.observedThroughAt.timeIntervalSince1970, 1234.5)
            XCTAssertEqual(timeline.first?.span.observationCount, 1)
            XCTAssertEqual(timeline.first?.frame.displayID, displayID)
            XCTAssertEqual(sessions.count, 1)
            XCTAssertEqual(sessions.first?.endReason, .legacyMigration)
            XCTAssertEqual(
                try Data(contentsOf: framesDirectory.appendingPathComponent(filename)),
                jpeg
            )
        }

        for _ in 0..<2 {
            let reopened = try FrameStore(directory: directory)
            let timeline = await reopened.getTimelineEntries()
            let sessions = await reopened.getCaptureSessions()
            XCTAssertEqual(timeline.map(\.span.id), [frameID])
            XCTAssertEqual(timeline.map(\.span.frameID), [frameID])
            XCTAssertEqual(timeline.map(\.span.observationCount), [1])
            XCTAssertEqual(sessions.count, 1)
            XCTAssertEqual(sessions.first?.endReason, .legacyMigration)
        }
    }

    func testPruningSharedAssetDeletesJPEGOnlyAfterFinalSpanReference() async throws {
        let store = try FrameStore(directory: directory)
        let base = Date(timeIntervalSince1970: 60_000)
        let jpeg = try XCTUnwrap(ImageEncoder.jpegData(from: makeImage(), quality: 0.8))
        _ = try await store.beginCaptureSession(at: base)
        let frame = StoredFrame(id: UUID(), timestamp: base, hash: 1, displayID: nil, displayName: nil)
        let firstMutation = try await store.recordEncodedCapture(frame: frame, jpegData: jpeg)
        guard case .inserted(let firstEntry) = firstMutation else {
            return XCTFail("Expected initial timeline entry")
        }
        try await store.endCaptureSession(reason: .paused)

        let secondSessionID = UUID()
        let secondSpanID = UUID()
        let databaseURL = directory.appendingPathComponent("frames.sqlite")
        try executeSQLite(
            databaseURL: databaseURL,
            sql:
                """
                PRAGMA foreign_keys=ON;
                INSERT INTO capture_sessions (id, started_at, ended_at, end_reason)
                VALUES ('\(secondSessionID.uuidString)', 60010, 60010, 'legacyMigration');
                INSERT INTO frame_spans (
                    id, frame_id, session_id, started_at, observed_through_at,
                    observation_count, display_id, display_name
                ) VALUES (
                    '\(secondSpanID.uuidString)', '\(frame.id.uuidString)',
                    '\(secondSessionID.uuidString)', 60010, 60010, 1, NULL, NULL
                );
                """
        )

        let firstRemovedAssets = try await store.pruneSpans(ids: [firstEntry.span.id])
        let payloadURL = framesDirectoryURL().appendingPathComponent("\(frame.id.uuidString).jpg")
        XCTAssertTrue(firstRemovedAssets.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: payloadURL.path))
        let afterFirstPrune = await store.getAllMetadata()
        XCTAssertEqual(afterFirstPrune.map(\.id), [frame.id])
        let referencesAfterFirstPrune = try await store.referencedFrameIDs(
            among: [frame.id, UUID()]
        )
        XCTAssertEqual(referencesAfterFirstPrune, [frame.id])

        let finalRemovedAssets = try await store.pruneSpans(ids: [secondSpanID])
        XCTAssertEqual(finalRemovedAssets, [frame.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: payloadURL.path))
        let afterFinalPrune = await store.getAllMetadata()
        XCTAssertTrue(afterFinalPrune.isEmpty)
        let referencesAfterFinalPrune = try await store.referencedFrameIDs(among: [frame.id])
        XCTAssertTrue(referencesAfterFinalPrune.isEmpty)
    }

    private func makeImage(width: Int = 8, height: Int = 8) throws -> CGImage {
        try XCTUnwrap(
            TestImageFactory.makeImage(width: width, height: height) { x, y in
                (UInt8((x * 31) % 256), UInt8((y * 17) % 256), 128)
            }
        )
    }

    private func framesDirectoryURL() -> URL {
        directory.appendingPathComponent("frames", isDirectory: true)
    }

    private func assertManagedSymlinkIsRejected(
        storageURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try FrameStore(directory: storageURL), file: file, line: line) { error in
            guard case FrameStoreError.recovery = error else {
                return XCTFail("Expected recovery error, got \(error)", file: file, line: line)
            }
        }
    }

    private func makeExternalDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FrameStoreExternal-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeExternalFile(contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FrameStoreExternal-\(UUID().uuidString).dat"
        )
        try contents.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeLegacyMetadata(hash: UInt64) throws -> FrameMetadata {
        let id = UUID()
        let jpeg = try XCTUnwrap(
            ImageEncoder.jpegData(from: makeImage(), quality: 0.8)
        )
        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
        try jpeg.write(to: framesDirectory.appendingPathComponent("\(id.uuidString).jpg"))
        return FrameMetadata(
            id: id,
            timestamp: Date(timeIntervalSince1970: 2_000.125),
            hash: hash,
            filename: "\(id.uuidString).jpg",
            thumbnailFilename: "\(id.uuidString)_thumb.jpg",
            fileSize: Int64(jpeg.count),
            displayID: UUID(),
            displayName: "Legacy Display"
        )
    }

    private func writeLegacyManifest(
        frames: [FrameMetadata],
        dateEncodingStrategy: JSONEncoder.DateEncodingStrategy
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = dateEncodingStrategy
        let manifest = FrameManifest(frames: frames, lastModified: Date(timeIntervalSince1970: 3_000))
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
    }

    private func recoveryBundleURLs() throws -> [URL] {
        let recoveryURL = FrameStore.recoveryDirectory(in: directory)
        guard FileManager.default.fileExists(atPath: recoveryURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: recoveryURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
    }

    private func recoveryContains(filename: String) -> Bool {
        recoveryFileURL(filename: filename) != nil
    }

    private func recoveryFileURL(filename: String) -> URL? {
        let recoveryURL = FrameStore.recoveryDirectory(in: directory)
        guard let enumerator = FileManager.default.enumerator(
            at: recoveryURL,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        for case let url as URL in enumerator where url.lastPathComponent == filename {
            return url
        }
        return nil
    }

    private func sqliteText(databaseURL: URL, sql: String) throws -> String {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let connection else {
            throw FrameDatabaseError.sqlite("Failed to inspect test database")
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 5_000)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw FrameDatabaseError.sqlite("Failed to inspect test pragma")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else {
            throw FrameDatabaseError.sqlite("Test pragma returned no text")
        }
        return String(cString: text)
    }

    private func sqliteInt(databaseURL: URL, sql: String) throws -> Int {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let connection else {
            throw FrameDatabaseError.sqlite("Failed to inspect test database")
        }
        defer { sqlite3_close(connection) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw FrameDatabaseError.sqlite("Failed to inspect test pragma")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw FrameDatabaseError.sqlite("Test pragma returned no integer")
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
            throw FrameDatabaseError.sqlite("Failed to create test database")
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 5_000)
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw FrameDatabaseError.sqlite("Failed to create malformed test schema")
        }
    }
}

private final class ClearRemovalFailureProbe: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var removalAllowed = false

    nonisolated func remove(_ url: URL) throws {
        lock.lock()
        let isAllowed = removalAllowed
        lock.unlock()
        guard isAllowed else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(at: url)
    }

    nonisolated func allowRemoval() {
        lock.lock()
        removalAllowed = true
        lock.unlock()
    }
}
