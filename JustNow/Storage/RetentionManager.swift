//
//  RetentionManager.swift
//  JustNow
//

import Foundation

nonisolated struct RetentionTier: Sendable, Equatable {
    let maxAge: TimeInterval
    let minimumSpacing: TimeInterval
}

nonisolated struct RetentionPolicy: Sendable, Equatable {
    let tiers: [RetentionTier]

    static let default24Hours = rewindHistory(
        RewindHistoryOption.defaultValue,
        captureInterval: AppStorageDefault.captureInterval,
        fullDetailWindow: RecentTimelineWindow.defaultValue.rawValue
    )

    static func rewindHistory(
        _ option: RewindHistoryOption,
        captureInterval: TimeInterval = AppStorageDefault.captureInterval,
        fullDetailWindow: TimeInterval = RecentTimelineWindow.defaultValue.rawValue
    ) -> RetentionPolicy {
        let maximumAge = option.retainedDuration
        let historyEnd = min(option.duration, maximumAge)
        let detailEnd = min(max(fullDetailWindow, captureInterval), historyEnd)
        let firstFalloffEnd = min(detailEnd * 2, historyEnd)
        let secondFalloffEnd = min(max(2 * 60 * 60, firstFalloffEnd), historyEnd)

        let detailSpacing = max(captureInterval, 0.25)
        let firstFalloffSpacing = max(detailSpacing * 4, 1)
        let secondFalloffSpacing = max(firstFalloffSpacing, 5)

        let archiveSpacing: TimeInterval
        switch option {
        case .thirtyMinutes:
            archiveSpacing = 30
        case .twoHours:
            archiveSpacing = 20
        case .eightHours:
            archiveSpacing = 25
        case .twentyFourHours:
            archiveSpacing = 30
        }

        var tiers: [RetentionTier] = []
        func appendTier(maxAge: TimeInterval, minimumSpacing: TimeInterval) {
            guard maxAge > (tiers.last?.maxAge ?? 0) else { return }
            tiers.append(RetentionTier(maxAge: maxAge, minimumSpacing: minimumSpacing))
        }

        appendTier(maxAge: detailEnd, minimumSpacing: detailSpacing)
        appendTier(maxAge: firstFalloffEnd, minimumSpacing: firstFalloffSpacing)
        appendTier(maxAge: secondFalloffEnd, minimumSpacing: secondFalloffSpacing)
        appendTier(maxAge: maximumAge, minimumSpacing: max(secondFalloffSpacing, archiveSpacing))

        return RetentionPolicy(tiers: tiers)
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

        for frame in frames {
            let age = currentTime.timeIntervalSince(frame.timestamp)

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
