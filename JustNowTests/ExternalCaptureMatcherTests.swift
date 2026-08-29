import XCTest
@testable import JustNow

final class ExternalCaptureMatcherTests: XCTestCase {
    func testSimulatorBundleIdentifierIsPresentAsSimulator() {
        let presence = ExternalCaptureMatcher.presence(
            in: [RunningAppDescriptor(bundleIdentifier: "com.apple.iphonesimulator")]
        )

        XCTAssertTrue(presence.isPresent)
        XCTAssertEqual(presence.kinds, [.simulator])
    }

    func testComputerUseLeftoversAreNotPresent() {
        let leftovers = [
            RunningAppDescriptor(bundleIdentifier: "SkyComputerUseClient"),
            RunningAppDescriptor(bundleIdentifier: "com.openai.sky.CUAService.cli")
        ]

        let presence = ExternalCaptureMatcher.presence(in: leftovers)

        XCTAssertFalse(presence.isPresent)
        XCTAssertTrue(presence.kinds.isEmpty)
    }

    func testCoreSimulatorHelpersAreNotPresent() {
        let leftovers = [
            RunningAppDescriptor(bundleIdentifier: "com.apple.SimStreamProcessorService"),
            RunningAppDescriptor(bundleIdentifier: "com.apple.CoreSimulator.CoreSimulatorService"),
            RunningAppDescriptor(bundleIdentifier: "com.apple.iphonesimulator.simruntime")
        ]

        let presence = ExternalCaptureMatcher.presence(in: leftovers)

        XCTAssertFalse(presence.isPresent)
        XCTAssertTrue(presence.kinds.isEmpty)
    }

    func testEmptyListIsNotPresent() {
        let presence = ExternalCaptureMatcher.presence(in: [])

        XCTAssertFalse(presence.isPresent)
        XCTAssertTrue(presence.kinds.isEmpty)
    }

    func testMixedSimulatorAndComputerUseLeftoversMatchOnlySimulator() {
        let apps = [
            RunningAppDescriptor(bundleIdentifier: "com.apple.iphonesimulator"),
            RunningAppDescriptor(bundleIdentifier: "SkyComputerUseClient"),
            RunningAppDescriptor(bundleIdentifier: "com.openai.sky.CUAService.cli"),
            RunningAppDescriptor(bundleIdentifier: "com.apple.SimStreamProcessorService")
        ]

        let presence = ExternalCaptureMatcher.presence(in: apps)

        XCTAssertTrue(presence.isPresent)
        XCTAssertEqual(presence.kinds, [.simulator])
    }
}
