//
//  TextCache.swift
//  JustNow
//

import Foundation

/// Caches OCR-extracted text for frames to speed up subsequent searches
actor TextCache {
    private var cache: [UUID: String] = [:]
    private let cacheURL: URL
    private var isDirty = false

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("JustNow", isDirectory: true)
        self.cacheURL = appDir.appendingPathComponent("text_cache.json")

        // Load existing cache synchronously during init
        if FileManager.default.fileExists(atPath: cacheURL.path),
           let data = try? Data(contentsOf: cacheURL),
           let loaded = try? JSONDecoder().decode([UUID: String].self, from: data) {
            self.cache = loaded
            print("[TextCache] Loaded \(loaded.count) cached entries")
        }
    }

    /// Get cached text for a frame, returns nil if not cached
    func getText(for frameID: UUID) -> String? {
        cache[frameID]
    }

    /// Cache extracted text for a frame
    func setText(_ text: String, for frameID: UUID) {
        cache[frameID] = text
        isDirty = true
    }

    /// Check if a frame has cached text
    func hasCachedText(for frameID: UUID) -> Bool {
        cache[frameID] != nil
    }

    /// Save cache to disk (call periodically or on app termination)
    func save() {
        guard isDirty else { return }

        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: cacheURL, options: .atomic)
            isDirty = false
        } catch {
            print("[TextCache] Failed to save: \(error)")
        }
    }

    /// Remove cached text for frames that no longer exist
    func prune(keepingFrameIDs validIDs: Set<UUID>) {
        let before = cache.count
        cache = cache.filter { validIDs.contains($0.key) }
        if cache.count != before {
            isDirty = true
            print("[TextCache] Pruned \(before - cache.count) stale entries")
        }
    }

    /// Clear all cached text
    func clear() {
        cache.removeAll()
        isDirty = true
        save()
    }

    var count: Int { cache.count }
}
