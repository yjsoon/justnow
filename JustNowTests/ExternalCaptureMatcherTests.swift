import XCTest
@testable import JustNow

final class ExternalCaptureMatcherTests: XCTestCase {
    private let leftoverBundleIdentifiers: Set<String> = [
        "com.openai.sky.CUAService.cli",
        "com.apple.CoreSimulator.SimStreamProcessorServices.SimStreamProcessorService",
        "com.apple.CoreSimulator.CoreSimulatorService",
        "com.apple.CoreSimulator.SimulatorTrampoline"
    ]

    func testSimulatorBundleIdentifierIsPresentAsSimulator() {
        let presence = ExternalCaptureMatcher.presence(
            in: [RunningAppDescriptor(bundleIdentifier: "com.apple.iphonesimulator")]
        )

        XCTAssertTrue(presence.isPresent)
        XCTAssertEqual(presence.kinds, [.simulator])
    }

    func testLeftoverBundleIdentifiersAreNotMatched() {
        let leftovers = leftoverBundleIdentifiers.map { RunningAppDescriptor(bundleIdentifier: $0) }
        let presence = ExternalCaptureMatcher.presence(in: leftovers)
        let ruleIdentifiers = Set(ExternalCaptureMatcher.rules.flatMap(\.bundleIdentifiers))

        XCTAssertFalse(presence.isPresent)
        XCTAssertTrue(presence.kinds.isEmpty)
        XCTAssertTrue(ruleIdentifiers.isDisjoint(with: leftoverBundleIdentifiers))
    }

    func testEmptyListIsNotPresent() {
        let presence = ExternalCaptureMatcher.presence(in: [])

        XCTAssertFalse(presence.isPresent)
        XCTAssertTrue(presence.kinds.isEmpty)
    }

    func testMixedSimulatorAndLeftoversMatchOnlySimulator() {
        let leftoverApps = leftoverBundleIdentifiers.map { RunningAppDescriptor(bundleIdentifier: $0) }
        let apps = [RunningAppDescriptor(bundleIdentifier: "com.apple.iphonesimulator")] + leftoverApps
        let presence = ExternalCaptureMatcher.presence(in: apps)

        XCTAssertTrue(presence.isPresent)
        XCTAssertEqual(presence.kinds, [.simulator])
    }
}
