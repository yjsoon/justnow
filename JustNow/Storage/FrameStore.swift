//
//  FrameStore.swift
//  JustNow
//

import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO

enum FrameStoreError: LocalizedError {
    case directoryCreationFailed
    case imageEncodingFailed
    case imageDecodingFailed
    case fileNotFound(UUID)
    case database(String)
    case frameAlreadyExists(UUID)
    case recovery(String)
    case storeInUse
    case noActiveCaptureSession
    case staleCaptureObservation
    case promotionConflict(String)
    case clearIncomplete([String])

    var errorDescription: String? {
        switch self {
        case .clearIncomplete(let paths):
            let visibleLimit = 5
            let names = paths.prefix(visibleLimit).map {
                URL(fileURLWithPath: $0).lastPathComponent
            }
            let remainder = max(0, paths.count - names.count)
            let locations = names.map { "• \($0)" }.joined(separator: "\n")
            let remainderDescription = remainder > 0 ? "\n…and \(remainder) more." : ""
            return "History was removed from the timeline, but some stored data could not be deleted. Try Clear All History again.\n\(locations)\(remainderDescription)"
        default:
            return nil
        }
    }
}

nonisolated enum FrameStoreCaptureMutation: Sendable, Equatable {
    case inserted(TimelineEntry)
    case extended(TimelineSpan)
}

nonisolated struct FrameSaveOptions: Sendable, Equatable {
    let quality: CGFloat

    static let standard = FrameSaveOptions(quality: ImageEncoder.fullImageQuality)
    static let lowPower = FrameSaveOptions(quality: ImageEncoder.lowPowerFullImageQuality)
}

typealias FrameStoreClearPayloadRemoval = @Sendable (URL) throws -> Void
typealias FrameStorePromotionPayloadDidWrite = @Sendable (TimelineEntry) throws -> Void

actor FrameStore {
    private struct PreparedStore {
        let database: FrameDatabase
        let storeID: String
        let migratedThisLaunch: Bool
    }

    private struct LegacyManifestPayload {
        let manifest: FrameManifest
        let fingerprint: String
    }

    private static let projectionSampleLimitPerDisplay = 50
    private static let ownedStoreMarkerFilename = ".store-id"
    private static let databaseFilename = "frames.sqlite"
    private static let manifestFilename = "manifest.json"
    private static let migratedManifestFilename = "manifest.json.migrated"
    private static let recoveryDirectoryName = "recovery"
    private static let lockFilename = ".store.lock"

    private let fileManager = FileManager.default
    private let storageURL: URL
    private let framesURL: URL
    private let databaseURL: URL
    private let manifestURL: URL
    private let migratedManifestURL: URL
    private let recoveryURL: URL
    private let markerURL: URL
    private let storeLock: FrameStoreLock
    private let database: FrameDatabase
    private let storeID: String
    private let instrumentation: CapturePersistenceInstrumentation?
    private let screenshotsDirectory: URL?
    private let clearPayloadRemoval: FrameStoreClearPayloadRemoval?
    private let promotionPayloadDidWrite: FrameStorePromotionPayloadDidWrite?
    private var pendingClearURLs: [URL] = []

    static func defaultStorageDirectory() throws -> URL {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw FrameStoreError.directoryCreationFailed
        }
        return appSupport.appendingPathComponent("JustNow", isDirectory: true)
    }

    static func recoveryDirectory(in storageURL: URL) -> URL {
        storageURL.appendingPathComponent(recoveryDirectoryName, isDirectory: true)
    }

    static func migratedManifestURL(in storageURL: URL) -> URL {
        storageURL.appendingPathComponent(migratedManifestFilename)
    }

    static func ownedStoreMarkerURL(in storageURL: URL) -> URL {
        storageURL
            .appendingPathComponent("frames", isDirectory: true)
            .appendingPathComponent(ownedStoreMarkerFilename)
    }

    /// `directory` is injectable so tests can run against a temporary
    /// location instead of the live Application Support store.
    init(
        directory: URL? = nil,
        instrumentation: CapturePersistenceInstrumentation? = nil,
        screenshotsDirectory: URL? = nil,
        clearPayloadRemoval: FrameStoreClearPayloadRemoval? = nil,
        promotionPayloadDidWrite: FrameStorePromotionPayloadDidWrite? = nil,
        durableCommitHook: FrameDatabaseCommitHook? = nil
    ) throws {
        self.instrumentation = instrumentation
        self.screenshotsDirectory = screenshotsDirectory
        self.clearPayloadRemoval = clearPayloadRemoval
        self.promotionPayloadDidWrite = promotionPayloadDidWrite
        storageURL = try directory ?? Self.defaultStorageDirectory()
        framesURL = storageURL.appendingPathComponent("frames", isDirectory: true)
        databaseURL = storageURL.appendingPathComponent(Self.databaseFilename)
        manifestURL = storageURL.appendingPathComponent(Self.manifestFilename)
        migratedManifestURL = storageURL.appendingPathComponent(Self.migratedManifestFilename)
        recoveryURL = Self.recoveryDirectory(in: storageURL)
        markerURL = framesURL.appendingPathComponent(Self.ownedStoreMarkerFilename)

        try FrameStoreFile.requireNotSymbolicLink(
            at: storageURL,
            description: "storage directory"
        )
        try FileManager.default.createDirectory(
            at: storageURL,
            withIntermediateDirectories: true,
            attributes: PrivateStorageProtection.ownerOnlyDirectoryAttributes
        )
        PrivateStorageProtection.apply(to: storageURL)
        try Self.validateManagedStorePaths(
            storageURL: storageURL,
            framesURL: framesURL,
            databaseURL: databaseURL,
            manifestURL: manifestURL,
            migratedManifestURL: migratedManifestURL,
            recoveryURL: recoveryURL
        )
        storeLock = try FrameStoreLock(
            url: storageURL.appendingPathComponent(Self.lockFilename)
        )

        let prepared = try Self.prepareStore(
            fileManager: fileManager,
            storageURL: storageURL,
            framesURL: framesURL,
            databaseURL: databaseURL,
            manifestURL: manifestURL,
            migratedManifestURL: migratedManifestURL,
            recoveryURL: recoveryURL,
            markerURL: markerURL,
            durableCommitHook: durableCommitHook
        )
        database = prepared.database
        storeID = prepared.storeID

        try Self.finaliseLegacyManifestBackupIfNeeded(
            fileManager: fileManager,
            database: database,
            manifestURL: manifestURL,
            migratedManifestURL: migratedManifestURL,
            recoveryURL: recoveryURL
        )
        try Self.advanceLegacyBackupRetentionIfNeeded(
            fileManager: fileManager,
            database: database,
            migratedThisLaunch: prepared.migratedThisLaunch,
            migratedManifestURL: migratedManifestURL
        )
    }

    deinit {
        // The database and its sidecars must be closed before another store can
        // acquire the lock and consider moving them into recovery.
        database.close()
        storeLock.release()
    }

    // MARK: - Public API

    func beginCaptureSession(at startedAt: Date) throws -> CaptureSession {
        do {
            return try database.beginCaptureSession(at: startedAt)
        } catch {
            throw FrameStoreError.database(String(describing: error))
        }
    }

    func endCaptureSession(id: UUID, reason: CaptureSessionEndReason) throws {
        do {
            try database.endCaptureSession(id: id, reason: reason)
        } catch {
            throw FrameStoreError.database(String(describing: error))
        }
    }

    func endCaptureSession(reason: CaptureSessionEndReason) throws {
        do {
            guard let active = try database.activeSession() else { return }
            try database.endCaptureSession(id: active.id, reason: reason)
        } catch {
            throw FrameStoreError.database(String(describing: error))
        }
    }

    func getTimelineEntries() -> [TimelineEntry] {
        do {
            return try database.allTimelineEntries()
        } catch {
            Self.logStorageDiagnostic("Failed to read timeline entries: \(error)")
            return []
        }
    }

    func getCaptureSessions() -> [CaptureSession] {
        do {
            return try database.allSessions()
        } catch {
            Self.logStorageDiagnostic("Failed to read capture sessions: \(error)")
            return []
        }
    }

    func saveFrame(
        _ cgImage: CGImage,
        timestamp: Date,
        hash: UInt64,
        displayID: UUID?,
        displayName: String?,
        options: FrameSaveOptions = .standard
    ) throws -> FrameMetadata {
        let id = UUID()
        guard let jpegData = ImageEncoder.jpegData(from: cgImage, quality: options.quality) else {
            throw FrameStoreError.imageEncodingFailed
        }
        instrumentation?.recordEncodedJPEG(jpegData, displayID: displayID)
        let metadata = try saveEncodedFrame(
            id: id,
            jpegData: jpegData,
            timestamp: timestamp,
            hash: hash,
            displayID: displayID,
            displayName: displayName
        )
        instrumentation?.recordPersistedJPEG(jpegData, displayID: displayID)
        instrumentation?.recordMetadataWrite(byteCount: FrameDatabase.logicalByteCount(for: metadata))
        return metadata
    }

    /// Persist an already encoded capture without decoding or re-encoding it.
    /// The caller owns the stable frame identity so the same ID can survive a
    /// future transition between volatile and durable repository sources.
    func saveEncodedFrame(
        id: UUID,
        jpegData: Data,
        timestamp: Date,
        hash: UInt64,
        displayID: UUID?,
        displayName: String?
    ) throws -> FrameMetadata {
        try persistNewPayload(
            id: id,
            jpegData: jpegData,
            timestamp: timestamp,
            hash: hash,
            displayID: displayID,
            displayName: displayName,
            insert: { metadata in try self.database.insert(metadata) }
        )
    }

    private func persistNewPayload(
        id: UUID,
        jpegData: Data,
        timestamp: Date,
        hash: UInt64,
        displayID: UUID?,
        displayName: String?,
        insert: (FrameMetadata) throws -> Void
    ) throws -> FrameMetadata {
        let filename = "\(id.uuidString).jpg"
        let thumbnailFilename = "\(id.uuidString)_thumb.jpg"
        let fullPath = framesURL.appendingPathComponent(filename)
        let thumbnailPath = framesURL.appendingPathComponent(thumbnailFilename)

        do {
            guard try database.metadata(for: id) == nil,
                  !FrameStoreFile.exists(at: fullPath),
                  !FrameStoreFile.exists(at: thumbnailPath) else {
                throw FrameStoreError.frameAlreadyExists(id)
            }
        } catch let error as FrameStoreError {
            throw error
        } catch {
            throw FrameStoreError.database(String(describing: error))
        }

        let metadata = FrameMetadata(
            id: id,
            timestamp: timestamp,
            hash: hash,
            filename: filename,
            thumbnailFilename: thumbnailFilename,
            fileSize: Int64(jpegData.count),
            displayID: displayID,
            displayName: displayName
        )

        try jpegData.write(to: fullPath, options: .atomic)
        do {
            try insert(metadata)
        } catch {
            try? fileManager.removeItem(at: fullPath)
            throw FrameStoreError.database(String(describing: error))
        }

        return metadata
    }

    /// Records one capture accepted by FrameBuffer's existing cadence policy.
    /// Equality is established only by reading and comparing the complete
    /// encoded JPEG belonging to the active same-display span.
    func recordEncodedCapture(
        frame: StoredFrame,
        jpegData: Data,
        forceNewSpan: Bool = false
    ) throws -> FrameStoreCaptureMutation {
        let session: CaptureSession
        do {
            guard let active = try database.activeSession() else {
                throw FrameStoreError.noActiveCaptureSession
            }
            session = active
        } catch let error as FrameStoreError {
            throw error
        } catch {
            throw FrameStoreError.database(String(describing: error))
        }

        do {
            // Compare the persisted Unix-epoch representation. Constructing a
            // `Date` back from SQLite can shift its reference-date value by
            // one floating-point ULP even though the epoch double is exact,
            // which must not reject a capture exactly at session start.
            guard frame.timestamp.timeIntervalSince1970
                >= session.startedAt.timeIntervalSince1970 else {
                throw FrameStoreError.staleCaptureObservation
            }

            if !forceNewSpan,
               let activeEntry = try database.activeTimelineEntry(displayID: frame.displayID) {
                guard activeEntry.span.sessionID == session.id else {
                    throw FrameStoreError.database("Active span belongs to a closed capture session")
                }
                guard frame.timestamp.timeIntervalSince1970
                    >= activeEntry.span.observedThroughAt.timeIntervalSince1970 else {
                    throw FrameStoreError.staleCaptureObservation
                }
                let activeMetadata = try requiredMetadata(for: activeEntry.frame.id)
                if activeEntry.frame.id != frame.id,
                   Int64(jpegData.count) == activeMetadata.fileSize {
                    let activePath = framesURL.appendingPathComponent(activeMetadata.filename)
                    // A missing or unreadable active payload cannot be compared
                    // exactly. Remove its broken logical span before inserting
                    // the new frame so the live timeline cannot expose an
                    // entry whose payload is already unavailable.
                    let activeData = try? FrameStoreFile.readRegularFile(at: activePath)
                    if activeData == jpegData {
                        let extended = try database.extendSpan(
                            id: activeEntry.span.id,
                            observedAt: frame.timestamp,
                            displayName: frame.displayName
                        )
                        return .extended(extended)
                    } else if activeData == nil {
                        _ = try pruneSpans(ids: [activeEntry.span.id])
                    }
                }
            }

            var insertedEntry: TimelineEntry?
            _ = try persistNewPayload(
                id: frame.id,
                jpegData: jpegData,
                timestamp: frame.timestamp,
                hash: frame.hash,
                displayID: frame.displayID,
                displayName: frame.displayName,
                insert: { metadata in
                    insertedEntry = try self.database.insertCapture(
                        metadata,
                        spanID: frame.id,
                        sessionID: session.id
                    )
                }
            )
            guard let insertedEntry else {
                throw FrameStoreError.database("Inserted timeline entry could not be resolved")
            }
            return .inserted(insertedEntry)
        } catch let error as FrameStoreError {
            throw error
        } catch {
            throw FrameStoreError.database(String(describing: error))
        }
    }

    /// Persists a volatile entry without decoding or re-encoding its JPEG.
    /// The file is written before the atomic frame/span transaction. If that
    /// transaction fails, the owned orphan is intentionally retained so the
    /// exact retry can finish or startup recovery can quarantine it.
    func promoteVolatileEntry(
        _ entry: TimelineEntry,
        jpegData: Data
    ) throws -> DurablePersistenceResult {
        let metadata = promotionMetadata(for: entry, jpegByteCount: jpegData.count)
        let before: TimelineEntry?
        do {
            try database.validateVolatileEntryForPromotion(entry, metadata: metadata)
            before = try database.durableEntry(
                frameID: entry.frame.id,
                spanID: entry.span.id
            )
        } catch {
            throw mapPromotionDatabaseError(error)
        }

        let fullPath = framesURL.appendingPathComponent(metadata.filename)
        let thumbnailPath = framesURL.appendingPathComponent(metadata.thumbnailFilename)
        if before == nil, FrameStoreFile.exists(at: thumbnailPath) {
            throw FrameStoreError.promotionConflict(
                "Promotion thumbnail identity already exists"
            )
        }

        let writeReceipt: DurableJPEGWriteReceipt?
        if FrameStoreFile.exists(at: fullPath) {
            guard let existingData = try? FrameStoreFile.readRegularFile(at: fullPath),
                  existingData == jpegData else {
                throw FrameStoreError.promotionConflict(
                    "Promotion frame identity has different encoded bytes"
                )
            }
            writeReceipt = nil
        } else {
            try jpegData.write(to: fullPath, options: .atomic)
            let receipt = DurableJPEGWriteReceipt(
                writeToken: UUID(),
                frameID: entry.frame.id,
                jpegData: jpegData,
                displayID: entry.frame.displayID
            )
            writeReceipt = receipt
            do {
                try promotionPayloadDidWrite?(entry)
            } catch {
                throw promotionFailureAfterJPEGWrite(
                    error,
                    receipt: receipt
                )
            }
        }

        do {
            let result = try database.promoteVolatileEntry(entry, metadata: metadata)
            return DurablePersistenceResult(
                effect: result.effect,
                entry: result.entry,
                wroteDurableJPEG: writeReceipt != nil,
                logicalMetadataByteCount: result.logicalMetadataByteCount
            )
        } catch {
            if let reconciled = try? database.durableEntry(
                frameID: entry.frame.id,
                spanID: entry.span.id
            ),
            durableEntry(reconciled, covers: entry),
            let committedBytes = try? FrameStoreFile.readRegularFile(at: fullPath),
            committedBytes == jpegData {
                let metadataBytes = before == nil
                    ? FrameDatabase.logicalByteCount(for: reconciled)
                    : FrameDatabase.logicalByteCount(for: reconciled.span)
                return DurablePersistenceResult(
                    effect: .reconciledCommitted,
                    entry: reconciled,
                    wroteDurableJPEG: writeReceipt != nil,
                    logicalMetadataByteCount: metadataBytes
                )
            }
            let mappedError = mapPromotionDatabaseError(error)
            if let writeReceipt {
                throw promotionFailureAfterJPEGWrite(
                    mappedError,
                    receipt: writeReceipt
                )
            }
            throw mappedError
        }
    }

    /// Advances a promoted span using an absolute snapshot. Older and equal
    /// snapshots are metadata no-ops, so a stale retry cannot regress the
    /// display name. Only advancing snapshots may contribute a changed
    /// non-nil name, and nil never erases a committed name.
    func checkpointPromotedSpan(_ span: TimelineSpan) throws -> DurablePersistenceResult {
        let before: TimelineEntry?
        do {
            before = try database.durableEntry(frameID: span.frameID, spanID: span.id)
        } catch {
            throw mapPromotionDatabaseError(error)
        }

        do {
            return try database.checkpointPromotedSpan(span)
        } catch {
            if let before,
               let reconciled = try? database.durableEntry(
                   frameID: span.frameID,
                   spanID: span.id
               ),
               !durableEntry(before, covers: span),
               durableEntry(reconciled, covers: span) {
                return DurablePersistenceResult(
                    effect: .reconciledCommitted,
                    entry: reconciled,
                    wroteDurableJPEG: false,
                    logicalMetadataByteCount: FrameDatabase.logicalByteCount(for: reconciled.span)
                )
            }
            throw mapPromotionDatabaseError(error)
        }
    }

    /// Direct database-backed existence check. A matching filename without a
    /// committed frame/span join is deliberately not durable existence.
    func durableEntry(frameID: UUID, spanID: UUID) throws -> TimelineEntry? {
        do {
            return try database.durableEntry(frameID: frameID, spanID: spanID)
        } catch {
            throw FrameStoreError.database(String(describing: error))
        }
    }

    private func promotionMetadata(
        for entry: TimelineEntry,
        jpegByteCount: Int
    ) -> FrameMetadata {
        FrameMetadata(
            id: entry.frame.id,
            timestamp: entry.frame.timestamp,
            hash: entry.frame.hash,
            filename: "\(entry.frame.id.uuidString).jpg",
            thumbnailFilename: "\(entry.frame.id.uuidString)_thumb.jpg",
            fileSize: Int64(jpegByteCount),
            displayID: entry.frame.displayID,
            displayName: entry.frame.displayName
        )
    }

    private func durableEntry(
        _ committed: TimelineEntry,
        covers requested: TimelineEntry
    ) -> Bool {
        committed.frame.id == requested.frame.id
            && committed.frame.timestamp.timeIntervalSince1970
                == requested.frame.timestamp.timeIntervalSince1970
            && committed.frame.hash == requested.frame.hash
            && committed.frame.displayID == requested.frame.displayID
            && committed.frame.displayName == requested.frame.displayName
            && durableEntry(committed, covers: requested.span)
    }

    private func durableEntry(
        _ committed: TimelineEntry,
        covers requested: TimelineSpan
    ) -> Bool {
        committed.span.id == requested.id
            && committed.span.frameID == requested.frameID
            && committed.span.sessionID == requested.sessionID
            && committed.span.startedAt.timeIntervalSince1970
                == requested.startedAt.timeIntervalSince1970
            && committed.span.displayID == requested.displayID
            && (requested.displayName == nil
                || committed.span.displayName == requested.displayName)
            && committed.span.observedThroughAt.timeIntervalSince1970
                >= requested.observedThroughAt.timeIntervalSince1970
            && committed.span.observationCount >= requested.observationCount
    }

    private func promotionFailureAfterJPEGWrite(
        _ error: Error,
        receipt: DurableJPEGWriteReceipt
    ) -> DurablePromotionFailure {
        DurablePromotionFailure(
            writeReceipt: receipt,
            underlyingDescription: String(describing: error)
        )
    }

    private func mapPromotionDatabaseError(_ error: Error) -> FrameStoreError {
        switch error {
        case FrameDatabaseError.invalidPromotion(let message),
             FrameDatabaseError.promotionConflict(let message):
            return .promotionConflict(message)
        case FrameDatabaseError.captureSessionNotFound(let id):
            return .promotionConflict("Capture session not found: \(id.uuidString)")
        case FrameDatabaseError.captureSessionMismatch(let expected, let active):
            return .promotionConflict(
                "Capture session mismatch (expected \(expected.uuidString), "
                    + "active \(active?.uuidString ?? "none"))"
            )
        default:
            return .database(String(describing: error))
        }
    }

    func loadFullImage(id: UUID) throws -> CGImage {
        let metadata = try requiredMetadata(for: id)
        let path = framesURL.appendingPathComponent(metadata.filename)
        guard let data = try? FrameStoreFile.readRegularFile(at: path) else {
            throw FrameStoreError.fileNotFound(id)
        }
        guard let image = ImageEncoder.cgImage(from: data) else {
            throw FrameStoreError.imageDecodingFailed
        }
        return image
    }

    /// Returns the immutable encoded payload without decoding or re-encoding.
    /// The hybrid repository uses it only for exact-byte comparison and RAM
    /// fallback resolution.
    func encodedPayload(id: UUID) throws -> Data {
        let metadata = try requiredMetadata(for: id)
        let path = framesURL.appendingPathComponent(metadata.filename)
        guard let data = try? FrameStoreFile.readRegularFile(at: path) else {
            throw FrameStoreError.fileNotFound(id)
        }
        return data
    }

    func loadSearchIndexImage(id: UUID, maxPixelSize: Int) throws -> CGImage {
        let metadata = try requiredMetadata(for: id)
        let path = framesURL.appendingPathComponent(metadata.filename)
        guard let data = try? FrameStoreFile.readRegularFile(at: path) else {
            throw FrameStoreError.fileNotFound(id)
        }
        guard let image = ImageEncoder.cgImage(from: data, maxPixelSize: maxPixelSize) else {
            throw FrameStoreError.imageDecodingFailed
        }
        return image
    }

    /// Copy the frame's stored JPEG to the user's chosen screenshots location,
    /// preserving original pixel dimensions and encoder quality.
    func copyFrameToScreenshotsLocation(id: UUID, timestamp: Date) throws -> URL {
        let metadata = try requiredMetadata(for: id)
        let sourcePath = framesURL.appendingPathComponent(metadata.filename)
        guard let sourceData = try? FrameStoreFile.readRegularFile(at: sourcePath) else {
            throw FrameStoreError.fileNotFound(id)
        }

        let ext = (metadata.filename as NSString).pathExtension
        return try saveEncodedFrameToScreenshotsLocation(sourceData, timestamp: timestamp, fileExtension: ext)
    }

    /// Exports already-encoded volatile JPEG bytes exactly as captured. This
    /// must never decode/re-encode a ring payload.
    func saveEncodedFrameToScreenshotsLocation(_ data: Data, timestamp: Date) throws -> URL {
        try saveEncodedFrameToScreenshotsLocation(data, timestamp: timestamp, fileExtension: "jpg")
    }

    func saveCroppedImageToScreenshotsLocation(image: CGImage, timestamp: Date) throws -> URL {
        guard let jpegData = ImageEncoder.jpegData(from: image, quality: ImageEncoder.fullImageQuality) else {
            throw FrameStoreError.imageEncodingFailed
        }

        let destinationDirectory = screenshotsDirectory
            ?? ScreenshotSaveLocation.resolveLive(fileManager: fileManager)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let baseName = "JustNow \(formatter.string(from: timestamp))"

        var destination = destinationDirectory.appendingPathComponent("\(baseName).jpg")
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = destinationDirectory.appendingPathComponent("\(baseName) (\(suffix)).jpg")
            suffix += 1
        }

        try jpegData.write(to: destination, options: .atomic)
        return destination
    }

    private func saveEncodedFrameToScreenshotsLocation(
        _ data: Data,
        timestamp: Date,
        fileExtension: String
    ) throws -> URL {
        let destinationDirectory = screenshotsDirectory
            ?? ScreenshotSaveLocation.resolveLive(fileManager: fileManager)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let baseName = "JustNow \(formatter.string(from: timestamp))"

        var destination = destinationDirectory.appendingPathComponent("\(baseName).\(fileExtension)")
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = destinationDirectory.appendingPathComponent("\(baseName) (\(suffix)).\(fileExtension)")
            suffix += 1
        }

        try data.write(to: destination, options: .atomic)
        return destination
    }

    func loadThumbnail(id: UUID) -> CGImage? {
        guard let metadata = try? requiredMetadata(for: id) else { return nil }
        let path = framesURL.appendingPathComponent(metadata.thumbnailFilename)
        if let data = try? FrameStoreFile.readRegularFile(at: path),
           let image = ImageEncoder.cgImage(from: data) {
            return image
        }

        // An unsafe thumbnail is disposable cache state. Remove only the path
        // itself (unlinking a symlink never touches its external target) before
        // generating a replacement.
        if FrameStoreFile.isSymbolicLink(at: path) {
            try? fileManager.removeItem(at: path)
        }

        guard let fullImage = try? loadFullImage(id: id),
              let thumbnail = ImageEncoder.generateThumbnail(from: fullImage),
              let thumbData = ImageEncoder.jpegData(from: thumbnail, quality: ImageEncoder.thumbnailQuality) else {
            return nil
        }

        try? thumbData.write(to: path, options: .atomic)
        return thumbnail
    }

    func getAllMetadata() -> [FrameMetadata] {
        do {
            return try database.allMetadata()
        } catch {
            Self.logStorageDiagnostic("Failed to read frame metadata: \(error)")
            return []
        }
    }

    func pruneSpans(ids: Set<UUID>) throws -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        let unreferencedRows: [FrameMetadata]
        do {
            unreferencedRows = try database.deleteSpans(ids: ids)
        } catch {
            throw FrameStoreError.database(String(describing: error))
        }

        // References are removed first. Any failed unlink is an owned orphan
        // that the existing startup recovery path will preserve.
        for metadata in unreferencedRows {
            try? fileManager.removeItem(at: framesURL.appendingPathComponent(metadata.filename))
            try? fileManager.removeItem(at: framesURL.appendingPathComponent(metadata.thumbnailFilename))
        }
        return Set(unreferencedRows.map(\.id))
    }

    func referencedFrameIDs(among frameIDs: Set<UUID>) throws -> Set<UUID> {
        do {
            return try database.referencedFrameIDs(among: frameIDs)
        } catch {
            throw FrameStoreError.database(String(describing: error))
        }
    }

    func pruneFrames(ids: Set<UUID>) throws {
        _ = try pruneSpans(ids: ids)
    }

    func clear() throws {
        let payloadFiles: [URL]
        do {
            guard try Self.readStoreMarker(at: markerURL) == storeID else {
                throw FrameStoreError.recovery("Active frames directory ownership changed")
            }
            payloadFiles = try Self.payloadFiles(
                fileManager: fileManager,
                framesURL: framesURL,
                markerURL: markerURL
            )
        } catch let error as FrameStoreError {
            throw error
        } catch {
            throw FrameStoreError.recovery(String(describing: error))
        }

        // The database transaction is the durable commit point. Everything
        // that can fail before it leaves rows and files untouched. Once it
        // succeeds, best-effort payload cleanup cannot make clear report a
        // misleading failure after history and sessions are already gone.
        do {
            try database.deleteAllFrames()
        } catch {
            throw FrameStoreError.database(String(describing: error))
        }

        let cleanupCandidates = pendingClearURLs
            + payloadFiles
            + [manifestURL, migratedManifestURL, recoveryURL]
        let uniqueCandidates = Dictionary(
            cleanupCandidates.map { ($0.standardizedFileURL.path, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { lhs, rhs in
            // Remove children before a directory that may contain them.
            lhs.pathComponents.count > rhs.pathComponents.count
        }
        var failedURLs: [URL] = []
        for url in uniqueCandidates where FrameStoreFile.exists(at: url) {
            do {
                if let clearPayloadRemoval {
                    try clearPayloadRemoval(url)
                } else {
                    try fileManager.removeItem(at: url)
                }
            } catch {
                if FrameStoreFile.exists(at: url) {
                    failedURLs.append(url)
                    Self.logStorageDiagnostic(
                        "Clear could not delete a managed history item; it will retry on the next clear."
                    )
                }
            }
        }
        pendingClearURLs = failedURLs
        if !failedURLs.isEmpty {
            throw FrameStoreError.clearIncomplete(failedURLs.map(\.path).sorted())
        }
    }

    func cleanupOrphans() throws {
        guard try Self.readStoreMarker(at: markerURL) == storeID else {
            throw FrameStoreError.recovery("Active frames directory ownership changed")
        }

        let rows: [FrameMetadata]
        do {
            rows = try database.allMetadata()
        } catch {
            throw FrameStoreError.database(String(describing: error))
        }

        let missingIDs = Set(rows.compactMap { metadata -> UUID? in
            let fullPath = framesURL.appendingPathComponent(metadata.filename)
            return FrameStoreFile.isRegularFile(at: fullPath) ? nil : metadata.id
        })
        if !missingIDs.isEmpty {
            do {
                try database.deleteFrames(ids: missingIDs)
            } catch {
                throw FrameStoreError.database(String(describing: error))
            }
        }

        let remainingRows = rows.filter { !missingIDs.contains($0.id) }
        let knownFiles = Set(remainingRows.flatMap { [$0.filename, $0.thumbnailFilename] })
        let files = try Self.payloadFiles(
            fileManager: fileManager,
            framesURL: framesURL,
            markerURL: markerURL
        )
        let unidentified = files.filter { !knownFiles.contains($0.lastPathComponent) }
        if !unidentified.isEmpty {
            _ = try Self.createRecoveryBundle(
                fileManager: fileManager,
                recoveryURL: recoveryURL,
                reason: "orphaned-frame-files",
                items: unidentified
            )
        }
    }

    func storageStatistics() -> FrameStorageStatistics {
        storageSnapshot().statistics
    }

    func storageSnapshot(
        logicalOverlay: [TimelineEntry] = []
    ) -> DurableFrameStorageSnapshot {
        do {
            let statistics = try database.storageStatistics(
                sampleLimitPerDisplay: Self.projectionSampleLimitPerDisplay,
                logicalOverlay: logicalOverlay
            )
            let allocated = sqliteAllocatedByteCounts()
            let combined = FrameStorageStatistics(
                durableJPEGPayloadBytes: statistics.durableJPEGPayloadBytes,
                knownSQLiteAllocatedBytes: allocated.total,
                sqliteWALAllocatedBytes: allocated.wal,
                frameCount: statistics.frameCount,
                durableFrameCount: statistics.durableFrameCount,
                timelineSpanCount: statistics.timelineSpanCount,
                observationCount: statistics.observationCount,
                projectionSamples: statistics.projectionSamples,
                displayCoverage: statistics.displayCoverage
            )
            return DurableFrameStorageSnapshot(statistics: combined)
        } catch {
            Self.logStorageDiagnostic("Failed to calculate frame statistics: \(error)")
            return DurableFrameStorageSnapshot(statistics: .empty)
        }
    }

    func durableJPEGPayloadBytes() -> Int64 {
        storageStatistics().durableJPEGPayloadBytes
    }

    private func sqliteAllocatedByteCounts() -> (total: Int64, wal: Int64) {
        let baseNames = ["frames.sqlite", "text_cache.sqlite"]
        var total: Int64 = 0
        var wal: Int64 = 0
        for baseName in baseNames {
            for suffix in ["", "-journal", "-wal", "-shm"] {
                let url = storageURL.appendingPathComponent(baseName + suffix)
                guard let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .totalFileAllocatedSizeKey,
                    .fileAllocatedSizeKey,
                    .fileSizeKey,
                ]), values.isRegularFile == true else { continue }
                let bytes = Int64(
                    values.totalFileAllocatedSize
                        ?? values.fileAllocatedSize
                        ?? values.fileSize
                        ?? 0
                )
                total += bytes
                if suffix == "-wal" { wal += bytes }
            }
        }
        return (total, wal)
    }

    func flush() {
        do {
            try database.checkpoint()
        } catch {
            Self.logStorageDiagnostic("Failed to checkpoint frame database: \(error)")
        }
    }

    // MARK: - Initialisation and migration

    private static func validateManagedStorePaths(
        storageURL: URL,
        framesURL: URL,
        databaseURL: URL,
        manifestURL: URL,
        migratedManifestURL: URL,
        recoveryURL: URL
    ) throws {
        let managedPaths = [
            (storageURL, "storage directory"),
            (framesURL, "frames directory"),
            (databaseURL, "frame database"),
            (URL(fileURLWithPath: databaseURL.path + "-journal"), "frame database journal"),
            (URL(fileURLWithPath: databaseURL.path + "-wal"), "frame database WAL"),
            (URL(fileURLWithPath: databaseURL.path + "-shm"), "frame database shared memory"),
            (manifestURL, "legacy manifest"),
            (migratedManifestURL, "migrated manifest"),
            (recoveryURL, "recovery directory")
        ]
        for (url, description) in managedPaths {
            try FrameStoreFile.requireNotSymbolicLink(at: url, description: description)
        }
    }

    private static func prepareStore(
        fileManager: FileManager,
        storageURL: URL,
        framesURL: URL,
        databaseURL: URL,
        manifestURL: URL,
        migratedManifestURL: URL,
        recoveryURL: URL,
        markerURL: URL,
        durableCommitHook: FrameDatabaseCommitHook?
    ) throws -> PreparedStore {
        try fileManager.createDirectory(
            at: storageURL,
            withIntermediateDirectories: true,
            attributes: PrivateStorageProtection.ownerOnlyDirectoryAttributes
        )
        PrivateStorageProtection.apply(to: storageURL, fileManager: fileManager)

        let databaseExisted = fileManager.fileExists(atPath: databaseURL.path)
        let databaseJournalURL = URL(fileURLWithPath: databaseURL.path + "-journal")
        let databaseWALURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let databaseSHMURL = URL(fileURLWithPath: databaseURL.path + "-shm")
        if !databaseExisted,
           (fileManager.fileExists(atPath: databaseJournalURL.path)
            || fileManager.fileExists(atPath: databaseWALURL.path)
            || fileManager.fileExists(atPath: databaseSHMURL.path)) {
            var interruptedDatabaseItems = [databaseJournalURL, databaseWALURL, databaseSHMURL]
            if !fileManager.fileExists(atPath: manifestURL.path) {
                interruptedDatabaseItems.append(framesURL)
                interruptedDatabaseItems.append(migratedManifestURL)
            }
            _ = try createRecoveryBundle(
                fileManager: fileManager,
                recoveryURL: recoveryURL,
                reason: "database-sidecars-without-main-database",
                items: interruptedDatabaseItems
            )
        }

        // SQLite may consume or remove a rollback journal while attempting to
        // open a corrupt database. Preserve an exact temporary copy so the
        // corrupt-store recovery bundle can still include that sidecar.
        var databaseJournalSnapshotURL: URL?
        if FrameStoreFile.isRegularFile(at: databaseJournalURL) {
            let snapshotURL = fileManager.temporaryDirectory.appendingPathComponent(
                "JustNow-\(UUID().uuidString)-frames.sqlite-journal"
            )
            try fileManager.copyItem(at: databaseJournalURL, to: snapshotURL)
            databaseJournalSnapshotURL = snapshotURL
        }
        defer {
            if let databaseJournalSnapshotURL {
                try? fileManager.removeItem(at: databaseJournalSnapshotURL)
            }
        }

        if !databaseExisted, !fileManager.fileExists(atPath: manifestURL.path) {
            var unidentifiedItems: [URL] = []
            if try hasPayloadFiles(fileManager: fileManager, framesURL: framesURL, markerURL: markerURL) {
                unidentifiedItems.append(framesURL)
            }
            if fileManager.fileExists(atPath: migratedManifestURL.path) {
                unidentifiedItems.append(migratedManifestURL)
            }
            if !unidentifiedItems.isEmpty {
                _ = try createRecoveryBundle(
                    fileManager: fileManager,
                    recoveryURL: recoveryURL,
                    reason: "files-without-frame-database",
                    items: unidentifiedItems
                )
            }
        }

        var database: FrameDatabase
        var openedDatabase: FrameDatabase?
        do {
            let candidate = try FrameDatabase(
                url: databaseURL,
                durableCommitHook: durableCommitHook
            )
            openedDatabase = candidate
            _ = try candidate.deleteFramesWithUnusableFilenames()
            _ = try candidate.allMetadata()
            _ = try candidate.allTimelineEntries()
            database = candidate
        } catch {
            openedDatabase?.close()
            if let databaseJournalSnapshotURL {
                if fileManager.fileExists(atPath: databaseJournalURL.path) {
                    try fileManager.removeItem(at: databaseJournalURL)
                }
                try fileManager.copyItem(
                    at: databaseJournalSnapshotURL,
                    to: databaseJournalURL
                )
            }
            _ = try createRecoveryBundle(
                fileManager: fileManager,
                recoveryURL: recoveryURL,
                reason: "corrupt-frame-database",
                items: recoverySet(
                    databaseURL: databaseURL,
                    framesURL: framesURL,
                    manifestURL: manifestURL,
                    migratedManifestURL: migratedManifestURL
                )
            )
            database = try FrameDatabase(
                url: databaseURL,
                durableCommitHook: durableCommitHook
            )
        }

        var storeID = try database.storeID
        var migratedThisLaunch = false

        if fileManager.fileExists(atPath: manifestURL.path),
           try database.metadataValue(for: "legacy_manifest_migration_state") != "complete" {
            do {
                guard try database.frameCount() == 0 else {
                    _ = try createRecoveryBundle(
                        fileManager: fileManager,
                        recoveryURL: recoveryURL,
                        reason: "unexpected-legacy-manifest",
                        items: [manifestURL]
                    )
                    try reconcileOwnedFramesDirectory(
                        fileManager: fileManager,
                        database: database,
                        framesURL: framesURL,
                        markerURL: markerURL,
                        recoveryURL: recoveryURL,
                        storeID: storeID
                    )
                    return PreparedStore(database: database, storeID: storeID, migratedThisLaunch: false)
                }

                let payload = try decodeLegacyManifest(at: manifestURL)
                try fileManager.createDirectory(at: framesURL, withIntermediateDirectories: true)
                try writeStoreMarker(storeID, to: markerURL)
                try database.importLegacyFrames(
                    payload.manifest.frames,
                    fingerprint: payload.fingerprint,
                    backupFilename: migratedManifestFilename
                )
                migratedThisLaunch = true
            } catch {
                database.close()
                _ = try createRecoveryBundle(
                    fileManager: fileManager,
                    recoveryURL: recoveryURL,
                    reason: "invalid-legacy-manifest",
                    items: recoverySet(
                        databaseURL: databaseURL,
                        framesURL: framesURL,
                        manifestURL: manifestURL,
                        migratedManifestURL: migratedManifestURL
                    )
                )
                database = try FrameDatabase(
                    url: databaseURL,
                    durableCommitHook: durableCommitHook
                )
                storeID = try database.storeID
                try fileManager.createDirectory(at: framesURL, withIntermediateDirectories: true)
                try writeStoreMarker(storeID, to: markerURL)
                return PreparedStore(database: database, storeID: storeID, migratedThisLaunch: false)
            }
        }

        try reconcileOwnedFramesDirectory(
            fileManager: fileManager,
            database: database,
            framesURL: framesURL,
            markerURL: markerURL,
            recoveryURL: recoveryURL,
            storeID: storeID
        )
        try database.quickCheck()
        return PreparedStore(
            database: database,
            storeID: storeID,
            migratedThisLaunch: migratedThisLaunch
        )
    }

    private static func decodeLegacyManifest(at url: URL) throws -> LegacyManifestPayload {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(decodeManifestDate)
        let manifest = try decoder.decode(FrameManifest.self, from: data)
        guard (1...2).contains(manifest.version) else {
            throw FrameStoreError.recovery("Unsupported legacy manifest version \(manifest.version)")
        }
        try validateLegacyFrames(manifest.frames)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return LegacyManifestPayload(manifest: manifest, fingerprint: digest)
    }

    private static func validateLegacyFrames(_ frames: [FrameMetadata]) throws {
        var ids = Set<UUID>()
        var filenames = Set<String>()
        for frame in frames {
            guard frame.timestamp.timeIntervalSince1970.isFinite,
                  frame.fileSize >= 0,
                  ids.insert(frame.id).inserted,
                  FrameStoreFilename.isSafe(frame.filename),
                  FrameStoreFilename.isSafe(frame.thumbnailFilename),
                  filenames.insert(FrameStoreFilename.collisionKey(frame.filename)).inserted,
                  filenames.insert(FrameStoreFilename.collisionKey(frame.thumbnailFilename)).inserted else {
                throw FrameStoreError.recovery("Invalid or duplicate legacy frame metadata")
            }
        }
    }

    private static func decodeManifestDate(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        if let timestamp = try? container.decode(TimeInterval.self), timestamp.isFinite {
            return Date(timeIntervalSince1970: timestamp)
        }
        let encodedDate = try container.decode(String.self)
        guard let date = ISO8601DateFormatter().date(from: encodedDate) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid manifest date: \(encodedDate)"
            )
        }
        return date
    }

    private static func finaliseLegacyManifestBackupIfNeeded(
        fileManager: FileManager,
        database: FrameDatabase,
        manifestURL: URL,
        migratedManifestURL: URL,
        recoveryURL: URL
    ) throws {
        guard try database.metadataValue(for: "legacy_manifest_migration_state") == "complete",
              fileManager.fileExists(atPath: manifestURL.path) else {
            return
        }

        let payload: LegacyManifestPayload
        do {
            payload = try decodeLegacyManifest(at: manifestURL)
        } catch {
            _ = try createRecoveryBundle(
                fileManager: fileManager,
                recoveryURL: recoveryURL,
                reason: "corrupt-post-migration-manifest",
                items: [manifestURL]
            )
            return
        }
        guard payload.fingerprint == (try database.metadataValue(for: "legacy_manifest_fingerprint")) else {
            _ = try createRecoveryBundle(
                fileManager: fileManager,
                recoveryURL: recoveryURL,
                reason: "changed-legacy-manifest",
                items: [manifestURL]
            )
            return
        }

        if fileManager.fileExists(atPath: migratedManifestURL.path) {
            _ = try createRecoveryBundle(
                fileManager: fileManager,
                recoveryURL: recoveryURL,
                reason: "superseded-manifest-backup",
                items: [migratedManifestURL]
            )
        }
        try fileManager.moveItem(at: manifestURL, to: migratedManifestURL)
    }

    private static func advanceLegacyBackupRetentionIfNeeded(
        fileManager: FileManager,
        database: FrameDatabase,
        migratedThisLaunch: Bool,
        migratedManifestURL: URL
    ) throws {
        guard !migratedThisLaunch,
              try database.metadataValue(for: "legacy_manifest_migration_state") == "complete" else {
            return
        }

        let healthyLaunches = Int(
            try database.metadataValue(for: "legacy_manifest_healthy_launches") ?? "0"
        ) ?? 0
        if healthyLaunches == 0 {
            // Keep the backup throughout the first later healthy launch.
            try database.setMetadataValue("1", for: "legacy_manifest_healthy_launches")
        } else if fileManager.fileExists(atPath: migratedManifestURL.path) {
            try fileManager.removeItem(at: migratedManifestURL)
            try database.setMetadataValue("removed", for: "legacy_manifest_backup_state")
        }
    }

    private static func reconcileOwnedFramesDirectory(
        fileManager: FileManager,
        database: FrameDatabase,
        framesURL: URL,
        markerURL: URL,
        recoveryURL: URL,
        storeID: String
    ) throws {
        try fileManager.createDirectory(at: framesURL, withIntermediateDirectories: true)
        let marker = try readStoreMarker(at: markerURL)
        let files = try payloadFiles(fileManager: fileManager, framesURL: framesURL, markerURL: markerURL)
        let rows = try database.allMetadata()
        if marker == storeID || (marker == nil && !rows.isEmpty) || (marker == nil && files.isEmpty) {
            var unusableFrameIDs = Set<UUID>()
            var unusableFiles: [URL] = []
            for metadata in rows {
                let payloadURL = framesURL.appendingPathComponent(metadata.filename)
                guard FrameStoreFile.isRegularFile(at: payloadURL) else {
                    unusableFrameIDs.insert(metadata.id)
                    let thumbnailURL = framesURL.appendingPathComponent(metadata.thumbnailFilename)
                    if FrameStoreFile.isRegularFile(at: thumbnailURL) {
                        unusableFiles.append(thumbnailURL)
                    }
                    continue
                }

                let payloadIsValid: Bool
                do {
                    let data = try FrameStoreFile.readRegularFile(at: payloadURL)
                    payloadIsValid = Int64(data.count) == metadata.fileSize
                        && ImageEncoder.cgImage(from: data) != nil
                } catch {
                    payloadIsValid = false
                }
                if !payloadIsValid {
                    unusableFrameIDs.insert(metadata.id)
                    unusableFiles.append(payloadURL)
                    let thumbnailURL = framesURL.appendingPathComponent(metadata.thumbnailFilename)
                    if FrameStoreFile.isRegularFile(at: thumbnailURL) {
                        unusableFiles.append(thumbnailURL)
                    }
                }
            }

            if !unusableFiles.isEmpty {
                _ = try createRecoveryBundle(
                    fileManager: fileManager,
                    recoveryURL: recoveryURL,
                    reason: "invalid-frame-payloads",
                    items: unusableFiles
                )
            }
            if !unusableFrameIDs.isEmpty {
                try database.deleteFrames(ids: unusableFrameIDs)
            }

            let usableRows = rows.filter { !unusableFrameIDs.contains($0.id) }
            let knownFiles = Set(usableRows.flatMap { [$0.filename, $0.thumbnailFilename] })
            let remainingFiles = try payloadFiles(
                fileManager: fileManager,
                framesURL: framesURL,
                markerURL: markerURL
            )
            let unidentified = remainingFiles.filter { !knownFiles.contains($0.lastPathComponent) }
            if !unidentified.isEmpty {
                _ = try createRecoveryBundle(
                    fileManager: fileManager,
                    recoveryURL: recoveryURL,
                    reason: "unidentified-frame-files",
                    items: unidentified
                )
            }
            if marker != storeID {
                try writeStoreMarker(storeID, to: markerURL)
            }
            return
        }

        _ = try createRecoveryBundle(
            fileManager: fileManager,
            recoveryURL: recoveryURL,
            reason: "mismatched-frame-store",
            items: [framesURL]
        )
        try fileManager.createDirectory(at: framesURL, withIntermediateDirectories: true)
        try writeStoreMarker(storeID, to: markerURL)
    }

    private static func readStoreMarker(at markerURL: URL) throws -> String? {
        guard FrameStoreFile.exists(at: markerURL) else { return nil }
        guard let data = try? FrameStoreFile.readRegularFile(at: markerURL),
              let encodedValue = String(data: data, encoding: .utf8) else {
            return nil
        }
        let value = encodedValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func writeStoreMarker(_ storeID: String, to markerURL: URL) throws {
        if FrameStoreFile.exists(at: markerURL), !FrameStoreFile.isRegularFile(at: markerURL) {
            try FileManager.default.removeItem(at: markerURL)
        }
        try Data("\(storeID)\n".utf8).write(to: markerURL, options: .atomic)
    }

    private static func hasPayloadFiles(
        fileManager: FileManager,
        framesURL: URL,
        markerURL: URL
    ) throws -> Bool {
        guard fileManager.fileExists(atPath: framesURL.path) else { return false }
        return try !payloadFiles(
            fileManager: fileManager,
            framesURL: framesURL,
            markerURL: markerURL
        ).isEmpty
    }

    private static func payloadFiles(
        fileManager: FileManager,
        framesURL: URL,
        markerURL: URL
    ) throws -> [URL] {
        guard fileManager.fileExists(atPath: framesURL.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: framesURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ).filter { url in
            guard url.lastPathComponent != markerURL.lastPathComponent,
                  FrameStoreFile.isRegularFile(at: url) else {
                return false
            }
            return true
        }
    }

    private static func recoverySet(
        databaseURL: URL,
        framesURL: URL,
        manifestURL: URL,
        migratedManifestURL: URL
    ) -> [URL] {
        [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-journal"),
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
            framesURL,
            manifestURL,
            migratedManifestURL
        ]
    }

    @discardableResult
    private static func createRecoveryBundle(
        fileManager: FileManager,
        recoveryURL: URL,
        reason: String,
        items: [URL]
    ) throws -> URL {
        try FrameStoreFile.requireNotSymbolicLink(
            at: recoveryURL,
            description: "recovery directory"
        )
        for item in items {
            try FrameStoreFile.requireNotSymbolicLink(
                at: item,
                description: "recovery source \(item.lastPathComponent)"
            )
        }
        let existingItems = items.filter { fileManager.fileExists(atPath: $0.path) }
        guard !existingItems.isEmpty else { return recoveryURL }

        try fileManager.createDirectory(at: recoveryURL, withIntermediateDirectories: true)
        let bundleURL = recoveryURL.appendingPathComponent(
            "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: false)

        do {
            for item in existingItems {
                var destination = bundleURL.appendingPathComponent(item.lastPathComponent)
                if fileManager.fileExists(atPath: destination.path) {
                    destination = bundleURL.appendingPathComponent(
                        "\(UUID().uuidString)-\(item.lastPathComponent)"
                    )
                }
                try fileManager.moveItem(at: item, to: destination)
            }
        } catch {
            throw FrameStoreError.recovery("Failed to preserve storage recovery bundle: \(error)")
        }

        logStorageDiagnostic(
            "Preserved \(existingItems.count) storage item(s) in recovery (\(reason))"
        )
        return bundleURL
    }

    private nonisolated static func logStorageDiagnostic(_ message: String) {
        Task { @MainActor in
            DiagnosticsLog.shared.log("Storage", message)
        }
    }

    private func requiredMetadata(for id: UUID) throws -> FrameMetadata {
        do {
            guard let metadata = try database.metadata(for: id) else {
                throw FrameStoreError.fileNotFound(id)
            }
            return metadata
        } catch let error as FrameStoreError {
            throw error
        } catch {
            throw FrameStoreError.database(String(describing: error))
        }
    }
}

/// Process-lifetime ownership of a storage directory. This prevents recovery
/// from renaming a database or WAL sidecar still open by another `FrameStore`
/// instance or JustNow process.
nonisolated final class FrameStoreLock: @unchecked Sendable {
    private var descriptor: Int32

    init(url: URL) throws {
        let opened = Darwin.open(
            url.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard opened >= 0 else {
            throw FrameStoreError.recovery("Failed to open frame store lock")
        }

        var fileStatus = stat()
        guard fstat(opened, &fileStatus) == 0,
              fileStatus.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(opened)
            throw FrameStoreError.recovery("Frame store lock is not a regular file")
        }

        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            Darwin.close(opened)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                throw FrameStoreError.storeInUse
            }
            throw FrameStoreError.recovery("Failed to acquire frame store lock")
        }
        descriptor = opened
    }

    deinit {
        release()
    }

    func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }
}

/// `lstat`/`O_NOFOLLOW` helpers for payloads that must never traverse a link.
nonisolated enum FrameStoreFile {
    static func requireNotSymbolicLink(at url: URL, description: String) throws {
        var fileStatus = stat()
        if lstat(url.path, &fileStatus) == 0 {
            guard fileStatus.st_mode & S_IFMT != S_IFLNK else {
                throw FrameStoreError.recovery("Refusing symlinked \(description)")
            }
            return
        }
        guard errno == ENOENT else {
            throw FrameStoreError.recovery("Failed to inspect \(description)")
        }
    }

    static func exists(at url: URL) -> Bool {
        var fileStatus = stat()
        return lstat(url.path, &fileStatus) == 0
    }

    static func isRegularFile(at url: URL) -> Bool {
        var fileStatus = stat()
        return lstat(url.path, &fileStatus) == 0
            && fileStatus.st_mode & S_IFMT == S_IFREG
    }

    static func isSymbolicLink(at url: URL) -> Bool {
        var fileStatus = stat()
        return lstat(url.path, &fileStatus) == 0
            && fileStatus.st_mode & S_IFMT == S_IFLNK
    }

    static func readRegularFile(at url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        return try handle.readToEnd() ?? Data()
    }
}
