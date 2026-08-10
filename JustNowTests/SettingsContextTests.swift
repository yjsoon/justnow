import XCTest
@testable import JustNow

@MainActor
final class SettingsContextTests: XCTestCase {
    func testRelaunchCallsInjectedAction() {
        var relaunchCount = 0
        let context = SettingsContext(onRelaunch: {
            relaunchCount += 1
        })

        context.relaunch()

        XCTAssertEqual(relaunchCount, 1)
    }
}
