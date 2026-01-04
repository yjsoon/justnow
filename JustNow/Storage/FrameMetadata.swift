//
//  FrameMetadata.swift
//  JustNow
//

import Foundation

struct FrameMetadata: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let hash: UInt64
    let filename: String
    let thumbnailFilename: String
    let fileSize: Int64
}

struct FrameManifest: Codable, Sendable {
    var version: Int = 1
    var frames: [FrameMetadata] = []
    var lastModified: Date = Date()
}
