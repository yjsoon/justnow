import CoreGraphics
import XCTest
@testable import JustNow

final class PerceptualHashTests: XCTestCase {
    /// Hash 0 is the "no hash" legacy sentinel that makes dedupe and timeline
    /// filtering treat a frame as always-keep. A uniform frame must therefore
    /// never hash to 0, or a static solid-colour screen would bypass duplicate
    /// detection and store every capture.
    func testUniformFramesNeverProduceLegacySentinelHash() async throws {
        let black = try XCTUnwrap(TestImageFactory.makeSolidImage(width: 32, height: 32, level: 0))
        let white = try XCTUnwrap(TestImageFactory.makeSolidImage(width: 32, height: 32, level: 255))
        let grey = try XCTUnwrap(TestImageFactory.makeSolidImage(width: 32, height: 32, level: 128))

        let blackHash = await PerceptualHash.compute(from: black)
        let whiteHash = await PerceptualHash.compute(from: white)
        let greyHash = await PerceptualHash.compute(from: grey)

        XCTAssertNotEqual(blackHash, 0)
        XCTAssertNotEqual(whiteHash, 0)
        XCTAssertNotEqual(greyHash, 0)
    }

    /// Uniform frames all collapse to the same hash regardless of brightness,
    /// so consecutive solid-colour captures dedupe against each other. The
    /// time-based minimum spacing in DuplicateFramePolicy still stores
    /// occasional frames of a static screen.
    func testUniformFramesShareOneHashSoTheyDedupeAgainstEachOther() async throws {
        let black = try XCTUnwrap(TestImageFactory.makeSolidImage(width: 16, height: 16, level: 0))
        let white = try XCTUnwrap(TestImageFactory.makeSolidImage(width: 16, height: 16, level: 255))

        let blackHash = await PerceptualHash.compute(from: black)
        let whiteHash = await PerceptualHash.compute(from: white)

        XCTAssertEqual(PerceptualHash.hammingDistance(blackHash, whiteHash), 0)
    }

    func testHashIsDeterministicForIdenticalContent() async throws {
        let first = try XCTUnwrap(makeCheckerboard(invert: false))
        let second = try XCTUnwrap(makeCheckerboard(invert: false))

        let firstHash = await PerceptualHash.compute(from: first)
        let secondHash = await PerceptualHash.compute(from: second)

        XCTAssertEqual(firstHash, secondHash)
        XCTAssertNotEqual(firstHash, 0)
    }

    func testStructurallyOppositeImagesAreFarApart() async throws {
        let left = try XCTUnwrap(
            TestImageFactory.makeImage(width: 64, height: 64) { x, _ in
                x < 32 ? (255, 255, 255) : (0, 0, 0)
            }
        )
        let right = try XCTUnwrap(
            TestImageFactory.makeImage(width: 64, height: 64) { x, _ in
                x < 32 ? (0, 0, 0) : (255, 255, 255)
            }
        )

        let leftHash = await PerceptualHash.compute(from: left)
        let rightHash = await PerceptualHash.compute(from: right)

        XCTAssertGreaterThanOrEqual(PerceptualHash.hammingDistance(leftHash, rightHash), 32)
    }

    func testHammingDistanceBasics() {
        XCTAssertEqual(PerceptualHash.hammingDistance(0, 0), 0)
        XCTAssertEqual(PerceptualHash.hammingDistance(.max, .max), 0)
        XCTAssertEqual(PerceptualHash.hammingDistance(0, .max), 64)
        XCTAssertEqual(
            PerceptualHash.hammingDistance(0b1011, 0b0001),
            PerceptualHash.hammingDistance(0b0001, 0b1011)
        )
    }

    private func makeCheckerboard(invert: Bool) -> CGImage? {
        TestImageFactory.makeImage(width: 64, height: 64) { x, y in
            let isLight = ((x / 8) + (y / 8)) % 2 == 0
            return (isLight != invert) ? (230, 230, 230) : (20, 20, 20)
        }
    }
}
