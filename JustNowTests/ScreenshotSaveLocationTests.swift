import XCTest
@testable import JustNow

final class ScreenshotSaveLocationTests: XCTestCase {
    private let desktop = URL(fileURLWithPath: "/Users/test/Desktop", isDirectory: true)

    /// Predicate that says only the supplied set of paths exist on disk.
    private func onlyExisting(_ paths: [String]) -> (URL) -> Bool {
        let set = Set(paths)
        return { set.contains($0.path) }
    }

    func testFallsThroughToDesktopWhenAllSourcesEmpty() {
        let inputs = ScreenshotSaveLocationInputs(
            overridePath: "",
            systemLocationRaw: nil,
            desktopURL: desktop
        )

        let resolved = ScreenshotSaveLocation.resolve(
            inputs: inputs,
            directoryExists: onlyExisting([desktop.path])
        )

        XCTAssertEqual(resolved, desktop)
    }

    func testFallsThroughToSystemLocationWhenOverrideMissing() {
        let systemPath = "/Volumes/External/Screens"
        let inputs = ScreenshotSaveLocationInputs(
            overridePath: "/Users/test/Nope",
            systemLocationRaw: systemPath,
            desktopURL: desktop
        )

        let resolved = ScreenshotSaveLocation.resolve(
            inputs: inputs,
            directoryExists: onlyExisting([systemPath, desktop.path])
        )

        XCTAssertEqual(resolved.path, systemPath)
    }

    func testExpandsTildeInSystemLocation() {
        let homeRelative = "~/Pictures/Shots"
        let expanded = (homeRelative as NSString).expandingTildeInPath

        let inputs = ScreenshotSaveLocationInputs(
            overridePath: "",
            systemLocationRaw: homeRelative,
            desktopURL: desktop
        )

        let resolved = ScreenshotSaveLocation.resolve(
            inputs: inputs,
            directoryExists: onlyExisting([expanded, desktop.path])
        )

        XCTAssertEqual(resolved.path, expanded)
    }

    func testSystemAbsolutePathThatDoesNotExistFallsThroughToDesktop() {
        let inputs = ScreenshotSaveLocationInputs(
            overridePath: "",
            systemLocationRaw: "/no/such/folder",
            desktopURL: desktop
        )

        let resolved = ScreenshotSaveLocation.resolve(
            inputs: inputs,
            directoryExists: onlyExisting([desktop.path])
        )

        XCTAssertEqual(resolved, desktop)
    }

    func testValidOverrideWinsOverEverything() {
        let override = "/Users/test/CustomShots"
        let inputs = ScreenshotSaveLocationInputs(
            overridePath: override,
            systemLocationRaw: "/Users/test/Pictures",
            desktopURL: desktop
        )

        let resolved = ScreenshotSaveLocation.resolve(
            inputs: inputs,
            directoryExists: onlyExisting([override, "/Users/test/Pictures", desktop.path])
        )

        XCTAssertEqual(resolved.path, override)
    }

    func testWhitespaceOnlyOverrideIsTreatedAsUnset() {
        let inputs = ScreenshotSaveLocationInputs(
            overridePath: "   ",
            systemLocationRaw: "/Users/test/Pictures",
            desktopURL: desktop
        )

        let resolved = ScreenshotSaveLocation.resolve(
            inputs: inputs,
            directoryExists: onlyExisting(["/Users/test/Pictures", desktop.path])
        )

        XCTAssertEqual(resolved.path, "/Users/test/Pictures")
    }
}
