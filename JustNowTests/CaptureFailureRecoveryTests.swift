import XCTest
@testable import JustNow

final class CaptureFailureRecoveryTests: XCTestCase {
    func testBacksOffWhenScreenCaptureKitFalselyReportsPermissionDenial() {
        let error = NSError(
            domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
            code: -3801
        )

        XCTAssertEqual(
            CaptureFailureRecovery.disposition(
                for: error,
                hasScreenRecordingPermission: true
            ),
            .backOff(CaptureFailureRecovery.falsePermissionDenialDelay)
        )
    }

    func testCountsRealPermissionDenialTowardsStop() {
        let error = NSError(
            domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
            code: -3801
        )

        XCTAssertEqual(
            CaptureFailureRecovery.disposition(
                for: error,
                hasScreenRecordingPermission: false
            ),
            .countTowardsStop
        )
    }

    func testCountsOtherScreenCaptureKitErrorsTowardsStop() {
        let error = NSError(
            domain: "com.apple.ScreenCaptureKit.CoreGraphicsErrorDomain",
            code: 1004
        )

        XCTAssertEqual(
            CaptureFailureRecovery.disposition(
                for: error,
                hasScreenRecordingPermission: true
            ),
            .countTowardsStop
        )
    }
}
