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

    func testLogWritesLine() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = DiagnosticsLog(directory: directory)
        log.log("Test", "first line")

        let fileURL = directory.appendingPathComponent("diagnostics.log")
        waitForFileWork(on: log, in: directory)

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("[Test] first line\n"))
    }

    /// End-to-end rotation: once the log passes the size cap, the next write
    /// must move it aside and start a fresh file containing only the new line.
    func testLogRotatesOversizedFileBeforeNextWrite() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = DiagnosticsLog(directory: directory)
        let oversizedMessage = String(repeating: "x", count: DiagnosticsLogFormat.maximumFileSize + 1)
        log.log("Big", oversizedMessage)
        log.log("After", "post-rotation line")
        waitForFileWork(on: log, in: directory)

        let currentURL = directory.appendingPathComponent("diagnostics.log")
        let rotatedURL = directory.appendingPathComponent("diagnostics.log.1")

        let current = try String(contentsOf: currentURL, encoding: .utf8)
        XCTAssertTrue(current.contains("[After] post-rotation line\n"))
        XCTAssertFalse(current.contains("[Big]"), "Oversized contents must have rotated out")

        let rotated = try String(contentsOf: rotatedURL, encoding: .utf8)
        XCTAssertTrue(rotated.contains("[Big]"))
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsLogTests-\(UUID().uuidString)", isDirectory: true)
    }

    /// The log serialises file IO on a private queue; a follow-up log call's
    /// side effects are visible once a barrier write drains behind the ones
    /// under test.
    private func waitForFileWork(on log: DiagnosticsLog, in directory: URL) {
        let drained = expectation(description: "log queue drained")
        log.log("Drain", "barrier")
        // Queue is FIFO and serial, so polling for the barrier line is enough.
        let fileURL = directory.appendingPathComponent("diagnostics.log")
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let contents = try? String(contentsOf: fileURL, encoding: .utf8),
                   contents.contains("[Drain] barrier") {
                    break
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            drained.fulfill()
        }
        wait(for: [drained], timeout: 6)
    }
}
