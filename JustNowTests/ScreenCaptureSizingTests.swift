import XCTest
@testable import JustNow

final class ScreenCaptureSizingTests: XCTestCase {
    func testOutputDimensionsClampDesiredScaleToOneForNonRetinaDisplay() {
        let output = ScreenCaptureSizing.outputDimensions(
            displayDimensions: (width: 2560, height: 1440),
            desiredScale: 2,
            displayBackingScale: 1
        )

        XCTAssertEqual(output.width, 2560)
        XCTAssertEqual(output.height, 1440)
    }

    func testOutputDimensionsUseDesiredScaleForRetinaDisplay() {
        let output = ScreenCaptureSizing.outputDimensions(
            displayDimensions: (width: 1728, height: 1117),
            desiredScale: 2,
            displayBackingScale: 2
        )

        XCTAssertEqual(output.width, 3456)
        XCTAssertEqual(output.height, 2234)
    }

    func testOutputDimensionsRespectLowPowerScaleOnRetinaDisplay() {
        let output = ScreenCaptureSizing.outputDimensions(
            displayDimensions: (width: 1728, height: 1117),
            desiredScale: 1,
            displayBackingScale: 2
        )

        XCTAssertEqual(output.width, 1728)
        XCTAssertEqual(output.height, 1117)
    }
}
