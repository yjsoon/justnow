import Foundation
import XCTest
@testable import JustNow

@MainActor
final class CapturePolicyControllerTests: XCTestCase {
    func testCaptureIntervalSettingClampsInvalidPersistedValues() {
        XCTAssertEqual(CaptureIntervalSetting.resolved(from: .nan), 0.25)
        XCTAssertEqual(CaptureIntervalSetting.resolved(from: .infinity), 0.25)
        XCTAssertEqual(CaptureIntervalSetting.resolved(from: -.infinity), 0.25)
        XCTAssertEqual(CaptureIntervalSetting.resolved(from: -1), 0.25)
        XCTAssertEqual(CaptureIntervalSetting.resolved(from: 0), 0.25)
        XCTAssertEqual(CaptureIntervalSetting.resolved(from: 2), 2)
        XCTAssertEqual(CaptureIntervalSetting.resolved(from: 10), 5)
    }

    func testResolvePolicyClampsInvalidCaptureInterval() {
        let controller = CapturePolicyController()
        let policy = controller.resolvePolicy(
            settings: CapturePolicySettings(captureInterval: .infinity, reduceCaptureOnBattery: false),
            environment: CapturePolicyEnvironment(
                isOnBattery: false,
                isLowPowerModeEnabled: false,
                batteryChargeFraction: nil,
                idleDuration: 0,
                thermalState: .nominal
            )
        )

        XCTAssertEqual(policy.interval, 0.25)
        XCTAssertEqual(policy.duplicatePolicy, .exact(atMostEvery: 0.25))
    }

    func testQuarterSecondCaptureKeepsQuarterSecondChanges() {
        let controller = CapturePolicyController()
        let policy = controller.resolvePolicy(
            settings: CapturePolicySettings(captureInterval: 0.25, reduceCaptureOnBattery: false),
            environment: CapturePolicyEnvironment(
                isOnBattery: false,
                isLowPowerModeEnabled: false,
                batteryChargeFraction: nil,
                idleDuration: 0,
                thermalState: .nominal
            )
        )

        XCTAssertEqual(policy.interval, 0.25)
        XCTAssertEqual(policy.duplicatePolicy, .exact(atMostEvery: 0.25))
    }

    func testResolvePolicyUsesLowPowerProfileOnBattery() {
        let controller = CapturePolicyController()
        let policy = controller.resolvePolicy(
            settings: CapturePolicySettings(captureInterval: 2, reduceCaptureOnBattery: true),
            environment: CapturePolicyEnvironment(
                isOnBattery: true,
                isLowPowerModeEnabled: false,
                batteryChargeFraction: 0.8,
                idleDuration: 0,
                thermalState: .nominal
            )
        )

        XCTAssertEqual(policy.interval, 6)
        XCTAssertEqual(policy.scale, 1)
        XCTAssertEqual(policy.saveOptions, .lowPower)
        XCTAssertEqual(policy.duplicatePolicy, .lowPower)
        XCTAssertEqual(
            policy.ocrIndexingPolicy,
            OCRIndexingPolicy(
                isEnabled: true,
                minimumInterval: 10,
                maxQueueDepth: 60,
                maxFrameAge: 180,
                concurrentJobs: 2,
                searchImageMaxPixelSize: 1_000
            )
        )
        XCTAssertFalse(policy.shouldPreventAppNap)
    }

    func testResolvePolicyDisablesOCRAtCriticalBatteryCharge() {
        let controller = CapturePolicyController()
        let policy = controller.resolvePolicy(
            settings: CapturePolicySettings(captureInterval: 4, reduceCaptureOnBattery: true),
            environment: CapturePolicyEnvironment(
                isOnBattery: true,
                isLowPowerModeEnabled: false,
                batteryChargeFraction: 0.1,
                idleDuration: 0,
                thermalState: .nominal
            )
        )

        XCTAssertEqual(policy.interval, 24)
        XCTAssertEqual(policy.scale, 1)
        XCTAssertEqual(policy.saveOptions, .lowPower)
        XCTAssertEqual(policy.duplicatePolicy, .lowPower)
        XCTAssertEqual(
            policy.ocrIndexingPolicy,
            OCRIndexingPolicy(
                isEnabled: false,
                minimumInterval: 10,
                maxQueueDepth: 60,
                maxFrameAge: 180,
                concurrentJobs: 2,
                searchImageMaxPixelSize: 1_000
            )
        )
    }

    func testResolvePolicyCombinesIdleAndThermalConstraints() {
        let controller = CapturePolicyController()
        let policy = controller.resolvePolicy(
            settings: CapturePolicySettings(captureInterval: 2, reduceCaptureOnBattery: true),
            environment: CapturePolicyEnvironment(
                isOnBattery: false,
                isLowPowerModeEnabled: false,
                batteryChargeFraction: nil,
                idleDuration: 90,
                thermalState: .serious
            )
        )

        XCTAssertEqual(policy.interval, 16)
        XCTAssertEqual(policy.scale, 1)
        XCTAssertEqual(policy.saveOptions, .lowPower)
        XCTAssertEqual(policy.duplicatePolicy, .lowPower)
        XCTAssertEqual(
            policy.ocrIndexingPolicy,
            OCRIndexingPolicy(
                isEnabled: true,
                minimumInterval: 20,
                maxQueueDepth: 24,
                maxFrameAge: 180,
                concurrentJobs: 1,
                searchImageMaxPixelSize: 800
            )
        )
        XCTAssertTrue(policy.isIdle)
        XCTAssertFalse(policy.shouldPreventAppNap)
    }

    func testApplyIfNeededSkipsDuplicatePolicyApplications() {
        let controller = CapturePolicyController()
        let settings = CapturePolicySettings(captureInterval: 1, reduceCaptureOnBattery: false)
        let environment = CapturePolicyEnvironment(
            isOnBattery: false,
            isLowPowerModeEnabled: false,
            batteryChargeFraction: nil,
            idleDuration: 0,
            thermalState: .nominal
        )

        var appliedIntervals: [TimeInterval] = []
        var appNapStarts = 0
        var appNapStops = 0

        let applier = CapturePolicyApplier(
            updateCaptureInterval: { appliedIntervals.append($0) },
            updateCaptureScale: { _ in },
            updateFramePersistence: { _, _ in },
            updateOCRIndexingPolicy: { _ in },
            beginForegroundActivity: { appNapStarts += 1 },
            endForegroundActivity: { appNapStops += 1 }
        )

        controller.applyIfNeeded(
            settings: settings,
            environment: environment,
            isCapturing: true,
            applier: applier
        )
        controller.applyIfNeeded(
            settings: settings,
            environment: environment,
            isCapturing: true,
            applier: applier
        )

        XCTAssertEqual(appliedIntervals, [1])
        XCTAssertEqual(appNapStarts, 1)
        XCTAssertEqual(appNapStops, 0)
    }

    func testNoteUserActivityOnlyRefreshesWhenComingBackFromIdle() {
        let controller = CapturePolicyController()
        let idleSettings = CapturePolicySettings(captureInterval: 1, reduceCaptureOnBattery: true)
        let idleEnvironment = CapturePolicyEnvironment(
            isOnBattery: false,
            isLowPowerModeEnabled: false,
            batteryChargeFraction: nil,
            idleDuration: 120,
            thermalState: .nominal
        )

        controller.applyIfNeeded(
            settings: idleSettings,
            environment: idleEnvironment,
            isCapturing: false,
            applier: CapturePolicyApplier(
                updateCaptureInterval: { _ in },
                updateCaptureScale: { _ in },
                updateFramePersistence: { _, _ in },
                updateOCRIndexingPolicy: { _ in },
                beginForegroundActivity: {},
                endForegroundActivity: {}
            )
        )

        XCTAssertTrue(
            controller.noteUserActivity(
                at: Date(timeIntervalSinceReferenceDate: 10)
            )
        )
        XCTAssertFalse(
            controller.noteUserActivity(
                at: Date(timeIntervalSinceReferenceDate: 10.5)
            )
        )
        XCTAssertTrue(
            controller.noteUserActivity(
                at: Date(timeIntervalSinceReferenceDate: 11.1)
            )
        )
    }

    func testIdleTransitionDelayWaitsForThresholdWhileActive() {
        let controller = CapturePolicyController()

        XCTAssertEqual(controller.idleTransitionDelay(for: 0, isCapturing: true), controller.idleThreshold)
        XCTAssertEqual(controller.idleTransitionDelay(for: 45, isCapturing: true), controller.idleThreshold - 45)
        // Threshold crossed but idle policy not applied (e.g. adaptive capture off):
        // no tight re-check loop; the periodic policy timer covers it.
        XCTAssertNil(controller.idleTransitionDelay(for: controller.idleThreshold, isCapturing: true))
        XCTAssertNil(controller.idleTransitionDelay(for: 600, isCapturing: true))
    }

    func testIdleTransitionDelayPollsForKeyboardOnlyWakeWhileIdle() {
        let controller = CapturePolicyController()
        let settings = CapturePolicySettings(captureInterval: 1, reduceCaptureOnBattery: true)

        controller.applyIfNeeded(
            settings: settings,
            environment: makeEnvironment(idleDuration: 120),
            isCapturing: true,
            applier: makeNoOpApplier()
        )
        XCTAssertTrue(controller.isLastAppliedPolicyIdle)

        // While idle the delay is a short poll, whatever the idle duration, so
        // typing (seen only through the system idle duration) wakes capture quickly.
        XCTAssertEqual(controller.idleTransitionDelay(for: 120, isCapturing: true), controller.idleWakePollInterval)
        XCTAssertEqual(controller.idleTransitionDelay(for: 0.5, isCapturing: true), controller.idleWakePollInterval)
        XCTAssertLessThan(controller.idleWakePollInterval, controller.idleThreshold)

        // Keyboard-only activity: the poll reads a small system idle duration and
        // the controller leaves idle, then waits for the threshold again.
        controller.applyIfNeeded(
            settings: settings,
            environment: makeEnvironment(idleDuration: 0.5),
            isCapturing: true,
            applier: makeNoOpApplier()
        )
        XCTAssertFalse(controller.isLastAppliedPolicyIdle)
        XCTAssertEqual(controller.idleTransitionDelay(for: 0.5, isCapturing: true), controller.idleThreshold - 0.5)
    }

    func testIdleTransitionDelayDoesNotPollWhileIdleAndNotCapturing() {
        let controller = CapturePolicyController()

        controller.applyIfNeeded(
            settings: CapturePolicySettings(captureInterval: 1, reduceCaptureOnBattery: true),
            environment: makeEnvironment(idleDuration: 120),
            isCapturing: false,
            applier: makeNoOpApplier()
        )

        // Paused, locked or display asleep: no 5-second wakeups while the user is away.
        XCTAssertTrue(controller.isLastAppliedPolicyIdle)
        XCTAssertNil(controller.idleTransitionDelay(for: 120, isCapturing: false))
        XCTAssertNil(controller.idleTransitionDelay(for: 0.5, isCapturing: false))
        XCTAssertEqual(
            controller.idleTransitionDelay(for: 120, isCapturing: true),
            controller.idleWakePollInterval
        )
    }

    private func makeEnvironment(idleDuration: TimeInterval) -> CapturePolicyEnvironment {
        CapturePolicyEnvironment(
            isOnBattery: false,
            isLowPowerModeEnabled: false,
            batteryChargeFraction: nil,
            idleDuration: idleDuration,
            thermalState: .nominal
        )
    }

    private func makeNoOpApplier() -> CapturePolicyApplier {
        CapturePolicyApplier(
            updateCaptureInterval: { _ in },
            updateCaptureScale: { _ in },
            updateFramePersistence: { _, _ in },
            updateOCRIndexingPolicy: { _ in },
            beginForegroundActivity: {},
            endForegroundActivity: {}
        )
    }
}
