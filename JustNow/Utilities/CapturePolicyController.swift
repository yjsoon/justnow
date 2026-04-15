import Foundation

struct CapturePolicySettings: Equatable {
    let captureInterval: Double
    let reduceCaptureOnBattery: Bool
}

struct CapturePolicyEnvironment: Equatable {
    let isOnBattery: Bool
    let isLowPowerModeEnabled: Bool
    let batteryChargeFraction: Double?
    let idleDuration: TimeInterval
    let thermalState: ProcessInfo.ThermalState
}

struct CapturePolicy: Equatable {
    let interval: TimeInterval
    let scale: Int
    let saveOptions: FrameSaveOptions
    let duplicatePolicy: DuplicateFramePolicy
    let ocrIndexingPolicy: OCRIndexingPolicy
    let shouldPreventAppNap: Bool
    let isIdle: Bool
}

struct CapturePolicyApplier {
    let updateCaptureInterval: (TimeInterval) -> Void
    let updateCaptureScale: (Int) -> Void
    let updateFramePersistence: (FrameSaveOptions, DuplicateFramePolicy) -> Void
    let updateOCRIndexingPolicy: (OCRIndexingPolicy) -> Void
    let beginForegroundActivity: () -> Void
    let endForegroundActivity: () -> Void
}

@MainActor
final class CapturePolicyController {
    let idleThreshold: TimeInterval = 60
    let userActivityUpdateInterval: TimeInterval = 1

    private let batteryMultiplier: Double = 3
    private let batteryLowThreshold: Double = 0.3
    private let batteryCriticalThreshold: Double = 0.15
    private let batteryLowMultiplier: Double = 1.5
    private let batteryCriticalMultiplier: Double = 2
    private let thermalSeriousMultiplier: Double = 2
    private let thermalCriticalMultiplier: Double = 4
    private let maxCaptureInterval: Double = 30
    private let ocrIndexBaseInterval: TimeInterval = 2.5
    private let ocrIndexBatteryInterval: TimeInterval = 10
    private let ocrIndexIdleInterval: TimeInterval = 15
    private let ocrIndexThermalSeriousInterval: TimeInterval = 20
    private let ocrIndexMaxFrameAge: TimeInterval = 5 * 60
    private let ocrIndexBatteryMaxFrameAge: TimeInterval = 3 * 60
    private let ocrIndexBaseQueueDepth: Int = 120
    private let ocrIndexBatteryQueueDepth: Int = 60
    private let ocrIndexIdleQueueDepth: Int = 40
    private let ocrIndexThermalQueueDepth: Int = 24
    private let ocrIndexBaseConcurrentJobs: Int = 3
    private let ocrIndexBatteryConcurrentJobs: Int = 2
    private let ocrIndexIdleConcurrentJobs: Int = 2
    private let ocrIndexThermalConcurrentJobs: Int = 1
    private let ocrIndexBaseImageMaxPixelSize: Int = 1_200
    private let ocrIndexBatteryImageMaxPixelSize: Int = 1_000
    private let ocrIndexIdleImageMaxPixelSize: Int = 900
    private let ocrIndexThermalImageMaxPixelSize: Int = 800
    private let idleMultiplier: Double = 4

    private(set) var lastAppliedPolicy: CapturePolicy?
    private var lastUserActivityUpdate: Date = .distantPast

    var isLastAppliedPolicyIdle: Bool {
        lastAppliedPolicy?.isIdle == true
    }

    func currentPolicy(
        settings: CapturePolicySettings,
        environment: CapturePolicyEnvironment
    ) -> CapturePolicy {
        resolvePolicy(settings: settings, environment: environment)
    }

    func applyIfNeeded(
        settings: CapturePolicySettings,
        environment: CapturePolicyEnvironment,
        isCapturing: Bool,
        applier: CapturePolicyApplier
    ) {
        let policy = resolvePolicy(settings: settings, environment: environment)
        guard policy != lastAppliedPolicy else { return }
        lastAppliedPolicy = policy

        applier.updateCaptureInterval(policy.interval)
        applier.updateCaptureScale(policy.scale)
        applier.updateFramePersistence(policy.saveOptions, policy.duplicatePolicy)
        applier.updateOCRIndexingPolicy(policy.ocrIndexingPolicy)

        guard isCapturing else { return }
        if policy.shouldPreventAppNap {
            applier.beginForegroundActivity()
        } else {
            applier.endForegroundActivity()
        }
    }

    func resetAppliedPolicy() {
        lastAppliedPolicy = nil
    }

    func noteUserActivity(at now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(lastUserActivityUpdate) >= userActivityUpdateInterval else {
            return false
        }

        lastUserActivityUpdate = now
        return isLastAppliedPolicyIdle
    }

    func idleTransitionDelay(for idleDuration: TimeInterval) -> TimeInterval? {
        let remaining = max(idleThreshold - idleDuration, 0)
        return remaining > 0 ? remaining : nil
    }

    func resolvePolicy(
        settings: CapturePolicySettings,
        environment: CapturePolicyEnvironment
    ) -> CapturePolicy {
        let adaptiveEnabled = settings.reduceCaptureOnBattery
        let onBattery = adaptiveEnabled && environment.isOnBattery
        let lowPowerMode = adaptiveEnabled && environment.isLowPowerModeEnabled
        let batteryCharge = onBattery ? environment.batteryChargeFraction : nil
        let isIdle = adaptiveEnabled && environment.idleDuration >= idleThreshold
        let thermalState = environment.thermalState
        let isThermalConstrained = adaptiveEnabled && (thermalState == .serious || thermalState == .critical)

        var interval = settings.captureInterval
        var scale = 2
        var saveOptions = FrameSaveOptions.standard
        var duplicatePolicy = DuplicateFramePolicy.exact(atMostEvery: settings.captureInterval)
        var ocrIndexEnabled = true
        var ocrIndexInterval = ocrIndexBaseInterval
        var ocrIndexQueueDepth = ocrIndexBaseQueueDepth
        var ocrIndexMaxAge = ocrIndexMaxFrameAge
        var ocrIndexConcurrentJobs = ocrIndexBaseConcurrentJobs
        var ocrIndexImageMaxPixelSize = ocrIndexBaseImageMaxPixelSize

        if onBattery || lowPowerMode {
            scale = 1
            saveOptions = .lowPower
            interval *= batteryMultiplier
            duplicatePolicy = .lowPower

            ocrIndexInterval = ocrIndexBatteryInterval
            ocrIndexQueueDepth = ocrIndexBatteryQueueDepth
            ocrIndexMaxAge = ocrIndexBatteryMaxFrameAge
            ocrIndexConcurrentJobs = ocrIndexBatteryConcurrentJobs
            ocrIndexImageMaxPixelSize = ocrIndexBatteryImageMaxPixelSize
        }

        if let batteryCharge {
            if batteryCharge <= batteryCriticalThreshold {
                scale = 1
                saveOptions = .lowPower
                interval *= batteryCriticalMultiplier
                duplicatePolicy = .lowPower
                ocrIndexEnabled = false
            } else if batteryCharge <= batteryLowThreshold {
                scale = 1
                saveOptions = .lowPower
                interval *= batteryLowMultiplier
                duplicatePolicy = .lowPower

                ocrIndexInterval = max(ocrIndexInterval, ocrIndexBatteryInterval)
                ocrIndexQueueDepth = min(ocrIndexQueueDepth, ocrIndexBatteryQueueDepth)
                ocrIndexMaxAge = min(ocrIndexMaxAge, ocrIndexBatteryMaxFrameAge)
                ocrIndexConcurrentJobs = min(ocrIndexConcurrentJobs, ocrIndexBatteryConcurrentJobs)
                ocrIndexImageMaxPixelSize = min(ocrIndexImageMaxPixelSize, ocrIndexBatteryImageMaxPixelSize)
            }
        }

        if isIdle {
            interval *= idleMultiplier
            scale = 1
            saveOptions = .lowPower
            duplicatePolicy = .lowPower

            ocrIndexInterval = max(ocrIndexInterval, ocrIndexIdleInterval)
            ocrIndexQueueDepth = min(ocrIndexQueueDepth, ocrIndexIdleQueueDepth)
            ocrIndexConcurrentJobs = min(ocrIndexConcurrentJobs, ocrIndexIdleConcurrentJobs)
            ocrIndexImageMaxPixelSize = min(ocrIndexImageMaxPixelSize, ocrIndexIdleImageMaxPixelSize)
        }

        if isThermalConstrained {
            let multiplier = (thermalState == .critical) ? thermalCriticalMultiplier : thermalSeriousMultiplier
            interval *= multiplier
            scale = 1
            saveOptions = .lowPower
            duplicatePolicy = .lowPower

            if thermalState == .critical {
                ocrIndexEnabled = false
            } else {
                ocrIndexInterval = max(ocrIndexInterval, ocrIndexThermalSeriousInterval)
                ocrIndexQueueDepth = min(ocrIndexQueueDepth, ocrIndexThermalQueueDepth)
                ocrIndexMaxAge = min(ocrIndexMaxAge, ocrIndexBatteryMaxFrameAge)
                ocrIndexConcurrentJobs = min(ocrIndexConcurrentJobs, ocrIndexThermalConcurrentJobs)
                ocrIndexImageMaxPixelSize = min(ocrIndexImageMaxPixelSize, ocrIndexThermalImageMaxPixelSize)
            }
        }

        interval = min(interval, maxCaptureInterval)

        let ocrPolicy = OCRIndexingPolicy(
            isEnabled: ocrIndexEnabled,
            minimumInterval: ocrIndexInterval,
            maxQueueDepth: ocrIndexQueueDepth,
            maxFrameAge: ocrIndexMaxAge,
            concurrentJobs: ocrIndexConcurrentJobs,
            searchImageMaxPixelSize: ocrIndexImageMaxPixelSize
        )

        let batteryCanRelaxCadence = onBattery || lowPowerMode
        let allowAppNap = batteryCanRelaxCadence || isIdle || isThermalConstrained || interval >= 5
        let shouldPreventAppNap = !allowAppNap

        return CapturePolicy(
            interval: interval,
            scale: scale,
            saveOptions: saveOptions,
            duplicatePolicy: duplicatePolicy,
            ocrIndexingPolicy: ocrPolicy,
            shouldPreventAppNap: shouldPreventAppNap,
            isIdle: isIdle
        )
    }
}
