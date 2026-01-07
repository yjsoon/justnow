//
//  RetentionManager.swift
//  JustNow
//

import Foundation

struct RetentionTier {
    let maxAge: TimeInterval      // Frames older than this get pruned to next tier
    let keepEveryNth: Int         // Keep every Nth frame when in this tier
}

class RetentionManager {
    // Retention policy: more recent = denser
    // Tiers must be ordered by maxAge ascending
    static let tiers: [RetentionTier] = [
        RetentionTier(maxAge: 10, keepEveryNth: 1),      // 0-10s: keep all (~1s intervals)
        RetentionTier(maxAge: 60, keepEveryNth: 2),      // 10-60s: every 2nd (~2s intervals)
        RetentionTier(maxAge: 300, keepEveryNth: 5),     // 60s-5m: every 5th (~5s intervals)
    ]

    /// Returns IDs of frames to delete based on time-based retention policy
    func framesToPrune(frames: [StoredFrame], currentTime: Date) -> Set<UUID> {
        var toKeep = Set<UUID>()
        var tierFrameCounts: [Int] = Array(repeating: 0, count: Self.tiers.count)

        // Process newest to oldest
        for frame in frames.sorted(by: { $0.timestamp > $1.timestamp }) {
            let age = currentTime.timeIntervalSince(frame.timestamp)

            // Find which tier this frame belongs to
            guard let tierIndex = Self.tiers.firstIndex(where: { age <= $0.maxAge }) else {
                // Too old, will be pruned
                continue
            }

            let tier = Self.tiers[tierIndex]
            tierFrameCounts[tierIndex] += 1

            // Keep if it's the Nth frame for this tier
            if tierFrameCounts[tierIndex] % tier.keepEveryNth == 0 {
                toKeep.insert(frame.id)
            }
        }

        // Return IDs NOT in toKeep
        let allIds = Set(frames.map { $0.id })
        return allIds.subtracting(toKeep)
    }
}
