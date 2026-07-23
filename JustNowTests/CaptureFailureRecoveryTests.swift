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

    func testIsPermissionDenialMatchesScreenCaptureKitDenialSignature() {
        XCTAssertTrue(
            CaptureFailureRecovery.isPermissionDenial(
                NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3801)
            )
        )
        XCTAssertFalse(
            CaptureFailureRecovery.isPermissionDenial(
                NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3802)
            )
        )
        XCTAssertFalse(
            CaptureFailureRecovery.isPermissionDenial(
                NSError(domain: "com.apple.ScreenCaptureKit.CoreGraphicsErrorDomain", code: -3801)
            )
        )
        XCTAssertFalse(CaptureFailureRecovery.isPermissionDenial(CaptureError.permissionDenied))
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
