import XCTest
@testable import JustNow

final class FrameStoreFilenameTests: XCTestCase {
    func testGeneratedPayloadNamesAreSafe() {
        let id = UUID()
        XCTAssertTrue(FrameStoreFilename.isSafe("\(id.uuidString).jpg"))
        XCTAssertTrue(FrameStoreFilename.isSafe("\(id.uuidString)_thumb.jpg"))
    }

    func testTraversalAndReservedNamesAreRejected() {
        XCTAssertFalse(FrameStoreFilename.isSafe(".."))
        XCTAssertFalse(FrameStoreFilename.isSafe("."))
        XCTAssertFalse(FrameStoreFilename.isSafe(""))
        XCTAssertFalse(FrameStoreFilename.isSafe("../secret.jpg"))
        XCTAssertFalse(FrameStoreFilename.isSafe("frames/../secret.jpg"))
        XCTAssertFalse(FrameStoreFilename.isSafe("frames.sqlite"))
        XCTAssertFalse(FrameStoreFilename.isSafe(".store-id"))
        XCTAssertFalse(FrameStoreFilename.isSafe("manifest.json"))
    }
}