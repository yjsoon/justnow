import XCTest
@testable import JustNow

final class CapturePermissionPreflightTests: XCTestCase {
    func testGatePrefersOpenCircuitOverDeniedPreflight() {
        XCTAssertEqual(
            CapturePermissionGate.resolve(hasPermission: true, circuitIsOpen: true),
            .allowed
        )
        XCTAssertEqual(
            CapturePermissionGate.resolve(hasPermission: false, circuitIsOpen: true),
            .coolingDown
        )
        XCTAssertEqual(
            CapturePermissionGate.resolve(hasPermission: false, circuitIsOpen: false),
            .denied
        )
    }

    func testWaitForGrantReturnsImmediatelyWhenAlreadyGranted() async {
        var sleeps = 0
        let granted = await CapturePermissionPreflight.waitForGrant(
            hasPermission: { true },
            attempts: 4,
            interval: .milliseconds(400),
            sleep: { _ in sleeps += 1 }
        )

        XCTAssertTrue(granted)
        XCTAssertEqual(sleeps, 0)
    }

    func testWaitForGrantRecoversWhenPreflightFlips() async {
        var remainingDenials = 2
        var sleeps = 0
        let granted = await CapturePermissionPreflight.waitForGrant(
            hasPermission: {
                if remainingDenials > 0 {
                    remainingDenials -= 1
                    return false
                }
                return true
            },
            attempts: 4,
            interval: .milliseconds(400),
            sleep: { _ in sleeps += 1 }
        )

        XCTAssertTrue(granted)
        XCTAssertEqual(sleeps, 2)
    }

    func testWaitForGrantGivesUpWhenPreflightStaysDenied() async {
        var sleeps = 0
        let granted = await CapturePermissionPreflight.waitForGrant(
            hasPermission: { false },
            attempts: 3,
            interval: .milliseconds(400),
            sleep: { _ in sleeps += 1 }
        )

        XCTAssertFalse(granted)
        XCTAssertEqual(sleeps, 3)
    }

    func testUserDefaultsStoreRoundTripsAndClears() {
        let defaults = UserDefaults(suiteName: "sg.tk.JustNow.circuitStoreTests")!
        defaults.removePersistentDomain(forName: "sg.tk.JustNow.circuitStoreTests")
        let store = UserDefaultsCaptureCircuitStore(defaults: defaults)
        let openedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let recoveredAt = Date(timeIntervalSince1970: 1_700_000_130)

        store.save(
            PersistedCaptureCircuit(
                openedAt: openedAt,
                cooldownSeconds: 30,
                escalationLevel: 2,
                recoveredAt: recoveredAt
            )
        )

        let loaded = store.load()
        XCTAssertEqual(loaded?.cooldownSeconds, 30)
        XCTAssertEqual(loaded?.escalationLevel, 2)
        XCTAssertEqual(loaded?.openedAt.timeIntervalSince1970, openedAt.timeIntervalSince1970)
        XCTAssertEqual(loaded?.recoveredAt?.timeIntervalSince1970, recoveredAt.timeIntervalSince1970)

        store.clear()
        XCTAssertNil(store.load())
        defaults.removePersistentDomain(forName: "sg.tk.JustNow.circuitStoreTests")
    }
}
