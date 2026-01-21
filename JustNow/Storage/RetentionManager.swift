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
    // Tiers ordered by maxAge ascending; minInterval is seconds between kept frames
    static let tiers: [RetentionTier] = [
        RetentionTier(maxAge: 300, keepEveryNth: 1),     // 0-5m: keep all (for text recall)
        RetentionTier(maxAge: 900, keepEveryNth: 5),     // 5-15m: ~5s intervals
        RetentionTier(maxAge: 86400, keepEveryNth: 30),  // 15m-24h: ~30s intervals (archive)
    ]

    /// Returns IDs of frames to delete based on time-based retention policy
    func framesToPrune(frames: [StoredFrame], currentTime: Date) -> Set<UUID> {
        var toKeep = Set<UUID>()
        var lastKeptTime: [Int: Date] = [:]  // Last kept timestamp per tier

        // Process OLDEST to NEWEST so spacing is stable
        for frame in frames.sorted(by: { $0.timestamp < $1.timestamp }) {
            let age = currentTime.timeIntervalSince(frame.timestamp)

            // Find which tier this frame belongs to
            guard let tierIndex = Self.tiers.firstIndex(where: { age <= $0.maxAge }) else {
                // Too old, will be pruned
                continue
            }

            let tier = Self.tiers[tierIndex]
            let minInterval = TimeInterval(tier.keepEveryNth)

            if let lastTime = lastKeptTime[tierIndex] {
                // Keep if enough time passed since last kept frame in this tier
                if frame.timestamp.timeIntervalSince(lastTime) >= minInterval {
                    toKeep.insert(frame.id)
                    lastKeptTime[tierIndex] = frame.timestamp
                }
            } else {
                // First frame in tier, always keep
                toKeep.insert(frame.id)
                lastKeptTime[tierIndex] = frame.timestamp
            }
        }

        // Return IDs NOT in toKeep
        let allIds = Set(frames.map { $0.id })
        return allIds.subtracting(toKeep)
    }
}
