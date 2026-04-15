import Foundation
import XCTest
@testable import JustNow

private enum CapturePolicyControllerTestLifetime {
    static var retainedControllers: [CapturePolicyController] = []

    static func retain(_ controller: CapturePolicyController) {
        retainedControllers.append(controller)
    }
}

@MainActor
final class CapturePolicyControllerTests: XCTestCase {
    func testResolvePolicyUsesLowPowerProfileOnBattery() {
        let controller = CapturePolicyController()
        CapturePolicyControllerTestLifetime.retain(controller)

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
        CapturePolicyControllerTestLifetime.retain(controller)

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
        CapturePolicyControllerTestLifetime.retain(controller)

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
        CapturePolicyControllerTestLifetime.retain(controller)
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
        CapturePolicyControllerTestLifetime.retain(controller)
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
}
