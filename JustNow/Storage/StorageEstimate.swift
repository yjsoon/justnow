import Foundation

nonisolated enum StorageProjectionKind: Sendable, Equatable {
    case allDiskJPEGPayloadEstimate
    case conservativeAllDiskJPEGBound

    var title: String {
        switch self {
        case .allDiskJPEGPayloadEstimate: "Projected JPEG payloads"
        case .conservativeAllDiskJPEGBound: "Conservative disk JPEG bound"
        }
    }

    var qualifier: String {
        switch self {
        case .allDiskJPEGPayloadEstimate:
            "This estimates encoded JPEG payload bytes, not total allocated disk space."
        case .conservativeAllDiskJPEGBound:
            "This is a conservative all-disk JPEG bound; hybrid mode normally keeps fewer JPEG bytes durably."
        }
    }
}

nonisolated enum StorageEstimate {
    static let minimumSampleFrameCount = 10

    static func projectionKind(for storageMode: HistoryStorageMode) -> StorageProjectionKind {
        switch storageMode {
        case .allDisk: .allDiskJPEGPayloadEstimate
        case .hybridRAM: .conservativeAllDiskJPEGBound
        }
    }

    static func projectedFrameCountPerDisplay(
        policy: RetentionPolicy,
        captureInterval: TimeInterval
    ) -> Int {
        let captureCadence = CaptureIntervalSetting.resolved(from: captureInterval)
        var previousMaxAge: TimeInterval = 0
        var frameCount = policy.tiers.isEmpty ? 0.0 : 1.0

        for (index, tier) in policy.tiers.enumerated() {
            let duration = max(0, tier.maxAge - previousMaxAge)
            let captureSteps = max(1, ceil(tier.minimumSpacing / captureCadence))
            let effectiveSpacing = captureSteps * captureCadence
            if index == 0 {
                frameCount = floor(duration / effectiveSpacing) + 1
            } else {
                frameCount += ceil(duration / effectiveSpacing)
            }
            previousMaxAge = max(previousMaxAge, tier.maxAge)
        }

        guard frameCount.isFinite, frameCount < Double(Int.max) else {
            return Int.max
        }
        return Int(frameCount)
    }

    static func projectedBytes(
        policy: RetentionPolicy,
        captureInterval: TimeInterval,
        samples: [FrameStorageSample],
        connectedDisplayIDs: [UUID]
    ) -> Int64? {
        let fallbackStoredBytes = samples.reduce(Int64(0)) { $0 + $1.jpegPayloadBytes }
        let fallbackFrameCount = samples.reduce(0) { $0 + $1.frameCount }
        guard fallbackFrameCount >= minimumSampleFrameCount,
              fallbackStoredBytes > 0,
              !connectedDisplayIDs.isEmpty else {
            return nil
        }

        let fallbackAverageFrameSize = Double(fallbackStoredBytes) / Double(fallbackFrameCount)
        let projectedFrameCount = projectedFrameCountPerDisplay(
            policy: policy,
            captureInterval: captureInterval
        )
        guard projectedFrameCount > 0 else { return nil }
        let estimate = connectedDisplayIDs.reduce(0.0) { total, displayID in
            let sample = samples.first { $0.displayID == displayID }
            let averageFrameSize: Double
            if let sample, sample.frameCount >= minimumSampleFrameCount, sample.jpegPayloadBytes > 0 {
                averageFrameSize = Double(sample.jpegPayloadBytes) / Double(sample.frameCount)
            } else {
                averageFrameSize = fallbackAverageFrameSize
            }
            return total + averageFrameSize * Double(projectedFrameCount)
        }
        guard estimate.isFinite, estimate < Double(Int64.max) else { return nil }
        return Int64(estimate.rounded(.up))
    }
}
