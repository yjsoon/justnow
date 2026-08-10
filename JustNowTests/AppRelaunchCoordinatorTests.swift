import Foundation
import XCTest
@testable import JustNow

@MainActor
final class AppRelaunchCoordinatorTests: XCTestCase {
    func testPrepareRelaunchLaunchesOnce() throws {
        var launches: [(Int32, URL)] = []
        let coordinator = AppRelaunchCoordinator { processIdentifier, bundleURL in
            launches.append((processIdentifier, bundleURL))
        }
        let bundleURL = URL(fileURLWithPath: "/Applications/JustNow.app")

        XCTAssertTrue(try coordinator.prepareRelaunch(processIdentifier: 42, bundleURL: bundleURL))
        XCTAssertFalse(try coordinator.prepareRelaunch(processIdentifier: 43, bundleURL: bundleURL))
        XCTAssertEqual(launches.count, 1)
        XCTAssertEqual(launches.first?.0, 42)
        XCTAssertEqual(launches.first?.1, bundleURL)
    }

    func testSuccessorProcessWaitsForCurrentProcessBeforeOpeningBundle() {
        let bundleURL = URL(fileURLWithPath: "/Applications/Just Now.app")
        let process = AppRelaunchCoordinator.makeSuccessorProcess(
            processIdentifier: 314,
            bundleURL: bundleURL
        )

        XCTAssertEqual(process.executableURL?.path, "/bin/sh")
        XCTAssertEqual(
            process.arguments,
            [
                "-c",
                "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open -n \"$2\"",
                "justnow-relaunch",
                "314",
                "/Applications/Just Now.app"
            ]
        )
    }
}
