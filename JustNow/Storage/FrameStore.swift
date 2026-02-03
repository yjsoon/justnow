//
//  FrameStore.swift
//  JustNow
//

import Foundation
import CoreGraphics

enum FrameStoreError: Error {
    case directoryCreationFailed
    case imageEncodingFailed
    case imageDecodingFailed
    case fileNotFound(UUID)
    case manifestCorrupted
}

struct FrameSaveOptions: Sendable, Equatable {
    let quality: CGFloat
    let thumbnailQuality: CGFloat
    let generateThumbnail: Bool

    static let standard = FrameSaveOptions(
        quality: ImageEncoder.fullImageQuality,
        thumbnailQuality: ImageEncoder.thumbnailQuality,
        generateThumbnail: false
    )
    static let lowPower = FrameSaveOptions(
        quality: ImageEncoder.lowPowerFullImageQuality,
        thumbnailQuality: ImageEncoder.lowPowerThumbnailQuality,
        generateThumbnail: false
    )
}

actor FrameStore {
    private let fileManager = FileManager.default
    private let storageURL: URL
    private let framesURL: URL
    private let manifestURL: URL

    private var manifest: FrameManifest
    private var manifestDirty = false
    private var pendingManifestChanges = 0
    private var manifestSaveTask: Task<Void, Never>?

    private static let manifestSaveDelay: Duration = .seconds(5)
    private static let manifestSaveImmediateThreshold = 25

    init() throws {
        // ~/Library/Application Support/JustNow/
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw FrameStoreError.directoryCreationFailed
        }

        storageURL = appSupport.appendingPathComponent("JustNow", isDirectory: true)
        framesURL = storageURL.appendingPathComponent("frames", isDirectory: true)
        manifestURL = storageURL.appendingPathComponent("manifest.json")

        // Create directories
        try fileManager.createDirectory(at: framesURL, withIntermediateDirectories: true)

        // Load or create manifest
        if fileManager.fileExists(atPath: manifestURL.path) {
            let data = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(FrameManifest.self, from: data)
        } else {
            manifest = FrameManifest()
        }
    }

    // MARK: - Public API

    func saveFrame(
        _ cgImage: CGImage,
        timestamp: Date,
        hash: UInt64,
        options: FrameSaveOptions = .standard
    ) throws -> FrameMetadata {
        let id = UUID()
        let filename = "\(id.uuidString).jpg"
        let thumbnailFilename = "\(id.uuidString)_thumb.jpg"

        let fullPath = framesURL.appendingPathComponent(filename)
        let thumbPath = framesURL.appendingPathComponent(thumbnailFilename)

        // Encode full image
        guard let fullData = ImageEncoder.jpegData(from: cgImage, quality: options.quality) else {
            throw FrameStoreError.imageEncodingFailed
        }

        // Write files
        try fullData.write(to: fullPath)
        if options.generateThumbnail {
            guard let thumbnail = ImageEncoder.generateThumbnail(from: cgImage),
                  let thumbData = ImageEncoder.jpegData(from: thumbnail, quality: options.thumbnailQuality) else {
                throw FrameStoreError.imageEncodingFailed
            }
            try thumbData.write(to: thumbPath)
        }

        let metadata = FrameMetadata(
            id: id,
            timestamp: timestamp,
            hash: hash,
            filename: filename,
            thumbnailFilename: thumbnailFilename,
            fileSize: Int64(fullData.count)
        )

        manifest.frames.append(metadata)
        manifest.lastModified = Date()
        scheduleManifestSave()

        return metadata
    }

    func loadFullImage(id: UUID) throws -> CGImage {
        guard let metadata = manifest.frames.first(where: { $0.id == id }) else {
            throw FrameStoreError.fileNotFound(id)
        }

        let path = framesURL.appendingPathComponent(metadata.filename)
        guard let data = fileManager.contents(atPath: path.path),
              let image = ImageEncoder.cgImage(from: data) else {
            throw FrameStoreError.imageDecodingFailed
        }

        return image
    }

    func loadThumbnail(id: UUID) -> CGImage? {
        guard let metadata = manifest.frames.first(where: { $0.id == id }) else {
            return nil
        }

        let path = framesURL.appendingPathComponent(metadata.thumbnailFilename)
        if let data = fileManager.contents(atPath: path.path),
           let image = ImageEncoder.cgImage(from: data) {
            return image
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
        manifest.frames
    }

    func pruneFrames(ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }

        for id in ids {
            guard let metadata = manifest.frames.first(where: { $0.id == id }) else { continue }

            let fullPath = framesURL.appendingPathComponent(metadata.filename)
            let thumbPath = framesURL.appendingPathComponent(metadata.thumbnailFilename)
            try? fileManager.removeItem(at: fullPath)
            try? fileManager.removeItem(at: thumbPath)
        }

        manifest.frames.removeAll { ids.contains($0.id) }
        manifest.lastModified = Date()
        scheduleManifestSave()
    }

    func clear() throws {
        // Remove all frame files
        for frame in manifest.frames {
            let fullPath = framesURL.appendingPathComponent(frame.filename)
            let thumbPath = framesURL.appendingPathComponent(frame.thumbnailFilename)
            try? fileManager.removeItem(at: fullPath)
            try? fileManager.removeItem(at: thumbPath)
        }

        manifest.frames.removeAll()
        manifest.lastModified = Date()
        performManifestSave()
    }

    func cleanupOrphans() throws {
        // Get all files in frames directory
        guard let files = try? fileManager.contentsOfDirectory(at: framesURL, includingPropertiesForKeys: nil) else {
            return
        }

        let knownFiles = Set(manifest.frames.flatMap { [$0.filename, $0.thumbnailFilename] })

        // Remove orphaned files
        for file in files {
            if !knownFiles.contains(file.lastPathComponent) {
                try? fileManager.removeItem(at: file)
            }
        }

        // Remove manifest entries for missing files
        manifest.frames = manifest.frames.filter { frame in
            let fullPath = framesURL.appendingPathComponent(frame.filename)
            return fileManager.fileExists(atPath: fullPath.path)
        }

        performManifestSave()
    }

    func totalStorageSize() -> Int64 {
        manifest.frames.reduce(0) { $0 + $1.fileSize }
    }

    func flushManifest() {
        performManifestSave()
    }

    // MARK: - Private

    private func scheduleManifestSave() {
        manifestDirty = true
        pendingManifestChanges += 1

        if pendingManifestChanges >= Self.manifestSaveImmediateThreshold {
            performManifestSave()
            return
        }

        guard manifestSaveTask == nil else { return }
        manifestSaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.manifestSaveDelay)
            await self?.performManifestSave()
        }
    }

    private func performManifestSave() {
        guard manifestDirty else { return }
        manifestSaveTask?.cancel()
        manifestSaveTask = nil

        do {
            try saveManifest()
            manifestDirty = false
            pendingManifestChanges = 0
        } catch {
            manifestDirty = true
            print("[FrameStore] Failed to save manifest: \(error)")
        }
    }

    private func saveManifest() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL)
    }
}
