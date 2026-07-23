import XCTest
@testable import JustNow

final class ScreenshotCaptureExecutionTests: XCTestCase {
    func testRunKeepsSynchronousFrameworkWorkOffMainThread() async throws {
        let ranOnMainThread = try await ScreenshotCaptureExecution.run {
            Thread.isMainThread
        }

        XCTAssertFalse(ranOnMainThread)
    }
}
