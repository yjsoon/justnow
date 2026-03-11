//
//  RetentionManager.swift
//  JustNow
//

import Foundation

struct RetentionTier: Sendable, Equatable {
    let maxAge: TimeInterval
    let minimumSpacing: TimeInterval
}

struct RetentionPolicy: Sendable, Equatable {
    let maximumAge: TimeInterval
    let tiers: [RetentionTier]

    static let default24Hours = rewindHistory(RewindHistoryOption.defaultValue)

    static func rewindHistory(_ option: RewindHistoryOption) -> RetentionPolicy {
        let maximumAge = option.retainedDuration

        let tiers: [RetentionTier]
        switch option {
        case .thirtyMinutes:
            tiers = [
                RetentionTier(maxAge: 5 * 60, minimumSpacing: 1),
                RetentionTier(maxAge: 15 * 60, minimumSpacing: 5),
                RetentionTier(maxAge: option.duration, minimumSpacing: 15),
                RetentionTier(maxAge: maximumAge, minimumSpacing: 30),
            ]
        case .twoHours:
            tiers = [
                RetentionTier(maxAge: 5 * 60, minimumSpacing: 1),
                RetentionTier(maxAge: 15 * 60, minimumSpacing: 5),
                RetentionTier(maxAge: maximumAge, minimumSpacing: 20),
            ]
        case .eightHours:
            tiers = [
                RetentionTier(maxAge: 5 * 60, minimumSpacing: 1),
                RetentionTier(maxAge: 15 * 60, minimumSpacing: 5),
                RetentionTier(maxAge: maximumAge, minimumSpacing: 25),
            ]
        case .twentyFourHours:
            tiers = [
                RetentionTier(maxAge: 5 * 60, minimumSpacing: 1),
                RetentionTier(maxAge: 15 * 60, minimumSpacing: 5),
                RetentionTier(maxAge: maximumAge, minimumSpacing: 30),
            ]
        }

        return RetentionPolicy(maximumAge: maximumAge, tiers: tiers)
    }
}

@MainActor
final class RetentionManager {
    private var policy: RetentionPolicy

    init(policy: RetentionPolicy = .default24Hours) {
        self.policy = policy
    }

    func updatePolicy(_ policy: RetentionPolicy) {
        self.policy = policy
    }

    func framesToPrune(frames: [StoredFrame], currentTime: Date) -> Set<UUID> {
        var toKeep = Set<UUID>()
        var lastKeptTime: [Int: Date] = [:]

        for frame in frames.sorted(by: { $0.timestamp < $1.timestamp }) {
            let age = currentTime.timeIntervalSince(frame.timestamp)

            guard age <= policy.maximumAge else {
                continue
            }

            guard let tierIndex = policy.tiers.firstIndex(where: { age <= $0.maxAge }) else {
                continue
            }

            let tier = policy.tiers[tierIndex]
            if let lastTime = lastKeptTime[tierIndex] {
                if frame.timestamp.timeIntervalSince(lastTime) >= tier.minimumSpacing {
                    toKeep.insert(frame.id)
                    lastKeptTime[tierIndex] = frame.timestamp
                }
            } else {
                toKeep.insert(frame.id)
                lastKeptTime[tierIndex] = frame.timestamp
            }
        }

        let allIDs = Set(frames.map { $0.id })
        return allIDs.subtracting(toKeep)
    }
}
