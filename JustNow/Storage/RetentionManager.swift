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
    static let tiers: [RetentionTier] = [
        RetentionTier(maxAge: 30, keepEveryNth: 1),      // 0-30s: keep all
        RetentionTier(maxAge: 300, keepEveryNth: 2),     // 30s-5m: every 2nd
        RetentionTier(maxAge: 600, keepEveryNth: 5),     // 5-10m: every 5th
        RetentionTier(maxAge: 3600, keepEveryNth: 30),   // 10m-1h: every 30th
    ]

    func pruneFrames(frames: inout [StoredFrame], currentTime: Date) {
        var result: [StoredFrame] = []
        var tierFrameCounts: [Int] = Array(repeating: 0, count: Self.tiers.count)

        // Process newest to oldest
        for frame in frames.reversed() {
            let age = currentTime.timeIntervalSince(frame.timestamp)

            // Find which tier this frame belongs to
            guard let tierIndex = Self.tiers.firstIndex(where: { age <= $0.maxAge }) else {
                // Too old, drop it (CVPixelBuffer auto-released when frame is deallocated)
                continue
            }

            let tier = Self.tiers[tierIndex]
            tierFrameCounts[tierIndex] += 1

            // Keep if it's the Nth frame for this tier
            if tierFrameCounts[tierIndex] % tier.keepEveryNth == 0 {
                result.append(frame)
            }
            // Frames not kept will have their CVPixelBuffer auto-released
        }

        frames = result.reversed()
    }
}
