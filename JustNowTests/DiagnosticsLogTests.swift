import XCTest
@testable import JustNow

final class DiagnosticsLogTests: XCTestCase {
    func testLineFormat() {
        XCTAssertEqual(
            DiagnosticsLogFormat.line(
                timestamp: "2026-07-12 17:06:07.669",
                category: "Capture",
                message: "Screenshot capture failed"
            ),
            "2026-07-12 17:06:07.669 [Capture] Screenshot capture failed\n"
        )
    }

    func testShouldRotateOnlyAtOrAboveLimit() {
        XCTAssertFalse(DiagnosticsLogFormat.shouldRotate(fileSize: 0, maximumSize: 100))
        XCTAssertFalse(DiagnosticsLogFormat.shouldRotate(fileSize: 99, maximumSize: 100))
        XCTAssertTrue(DiagnosticsLogFormat.shouldRotate(fileSize: 100, maximumSize: 100))
        XCTAssertTrue(DiagnosticsLogFormat.shouldRotate(fileSize: 101, maximumSize: 100))
    }

    func testDescribeErrorIncludesDomainAndCode() {
        let error = NSError(
            domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
            code: -3801,
            userInfo: [NSLocalizedDescriptionKey: "The user declined TCCs"]
        )
        XCTAssertEqual(
            DiagnosticsLogFormat.describe(error),
            "The user declined TCCs [com.apple.ScreenCaptureKit.SCStreamErrorDomain code=-3801]"
        )
    }

    func testLogWritesLineAndRotates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsLogTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = DiagnosticsLog(directory: directory)
        log.log("Test", "first line")

        let fileURL = directory.appendingPathComponent("diagnostics.log")
        let expectation = expectation(description: "line written")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(contents.hasSuffix("[Test] first line\n"))
    }
}
