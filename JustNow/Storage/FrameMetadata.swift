//
//  FrameMetadata.swift
//  JustNow
//

import Foundation

nonisolated struct FrameMetadata: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let hash: UInt64
    let filename: String
    let thumbnailFilename: String
    let fileSize: Int64
    /// Stable display identifier. Nil for frames captured before multi-display support;
    /// treated as belonging to the primary display when surfaced.
    let displayID: UUID?
    /// Friendly name snapshotted at capture time, so the overlay can label
    /// frames from a display that is no longer connected.
    let displayName: String?
}

nonisolated struct FrameManifest: Codable, Sendable {
    var version: Int = 2
    var frames: [FrameMetadata] = []
    var lastModified: Date = Date()
}
