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

actor FrameStore {
    private let fileManager = FileManager.default
    private let storageURL: URL
    private let framesURL: URL
    private let manifestURL: URL

    private var manifest: FrameManifest

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
            manifest = try JSONDecoder().decode(FrameManifest.self, from: data)
        } else {
            manifest = FrameManifest()
        }
    }

    // MARK: - Public API

    func saveFrame(_ cgImage: CGImage, timestamp: Date, hash: UInt64) throws -> FrameMetadata {
        let id = UUID()
        let filename = "\(id.uuidString).jpg"
        let thumbnailFilename = "\(id.uuidString)_thumb.jpg"

        let fullPath = framesURL.appendingPathComponent(filename)
        let thumbPath = framesURL.appendingPathComponent(thumbnailFilename)

        // Encode full image
        guard let fullData = ImageEncoder.jpegData(from: cgImage, quality: ImageEncoder.fullImageQuality) else {
            throw FrameStoreError.imageEncodingFailed
        }

        // Generate and encode thumbnail
        guard let thumbnail = ImageEncoder.generateThumbnail(from: cgImage),
              let thumbData = ImageEncoder.jpegData(from: thumbnail, quality: ImageEncoder.thumbnailQuality) else {
            throw FrameStoreError.imageEncodingFailed
        }

        // Write files
        try fullData.write(to: fullPath)
        try thumbData.write(to: thumbPath)

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
        try saveManifest()

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
        guard let data = fileManager.contents(atPath: path.path) else {
            return nil
        }

        return ImageEncoder.cgImage(from: data)
    }

    func getAllMetadata() -> [FrameMetadata] {
        manifest.frames
    }

    func pruneExcessFrames(maxCount: Int) throws {
        guard manifest.frames.count > maxCount else { return }

        // Sort by timestamp (oldest first)
        let sorted = manifest.frames.sorted { $0.timestamp < $1.timestamp }
        let toRemove = sorted.prefix(sorted.count - maxCount)

        for frame in toRemove {
            let fullPath = framesURL.appendingPathComponent(frame.filename)
            let thumbPath = framesURL.appendingPathComponent(frame.thumbnailFilename)
            try? fileManager.removeItem(at: fullPath)
            try? fileManager.removeItem(at: thumbPath)
        }

        manifest.frames = Array(sorted.suffix(maxCount))
        manifest.lastModified = Date()
        try saveManifest()
    }

    func deleteFrame(id: UUID) throws {
        guard let index = manifest.frames.firstIndex(where: { $0.id == id }) else {
            return
        }

        let metadata = manifest.frames[index]
        let fullPath = framesURL.appendingPathComponent(metadata.filename)
        let thumbPath = framesURL.appendingPathComponent(metadata.thumbnailFilename)

        try? fileManager.removeItem(at: fullPath)
        try? fileManager.removeItem(at: thumbPath)

        manifest.frames.remove(at: index)
        manifest.lastModified = Date()
        try saveManifest()
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
        try saveManifest()
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

        try saveManifest()
    }

    func totalStorageSize() -> Int64 {
        manifest.frames.reduce(0) { $0 + $1.fileSize }
    }

    // MARK: - Private

    private func saveManifest() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL)
    }
}
