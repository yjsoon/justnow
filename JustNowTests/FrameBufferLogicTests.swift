import XCTest
@testable import JustNow

/// Tests for FrameBuffer-adjacent types and logic that can be verified without
/// constructing a full FrameBuffer (which requires disk I/O via FrameStore).
final class FrameBufferLogicTests: XCTestCase {

    // MARK: - StoredFrame

    func testStoredFrameIdentity() {
        let id = UUID()
        let frame = StoredFrame(id: id, timestamp: Date(), hash: 42)
        XCTAssertEqual(frame.id, id)
    }

    // MARK: - OCRIndexingPolicy

    func testDisabledPolicyValues() {
        let policy = OCRIndexingPolicy.disabled
        XCTAssertFalse(policy.isEnabled)
        XCTAssertEqual(policy.minimumInterval, 0)
        XCTAssertEqual(policy.maxQueueDepth, 0)
        XCTAssertEqual(policy.maxFrameAge, 0)
    }

    func testOCRIndexingPolicyEquatable() {
        let a = OCRIndexingPolicy(isEnabled: true, minimumInterval: 1, maxQueueDepth: 10, maxFrameAge: 300)
        let b = OCRIndexingPolicy(isEnabled: true, minimumInterval: 1, maxQueueDepth: 10, maxFrameAge: 300)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, .disabled)
    }

    // MARK: - FrameSaveOptions

    func testStandardSaveOptions() {
        let opts = FrameSaveOptions.standard
        XCTAssertEqual(opts.quality, ImageEncoder.fullImageQuality)
        XCTAssertEqual(opts.thumbnailQuality, ImageEncoder.thumbnailQuality)
        XCTAssertFalse(opts.generateThumbnail)
    }

    func testLowPowerSaveOptions() {
        let opts = FrameSaveOptions.lowPower
        XCTAssertEqual(opts.quality, ImageEncoder.lowPowerFullImageQuality)
        XCTAssertLessThan(opts.quality, FrameSaveOptions.standard.quality,
                          "Low power quality should be lower than standard")
    }

    // MARK: - FrameMetadata Codable

    func testFrameMetadataRoundTripsViaJSON() throws {
        let original = FrameMetadata(
            id: UUID(),
            timestamp: Date(timeIntervalSinceReferenceDate: 1000),
            hash: 0xDEADBEEF,
            filename: "test.jpg",
            thumbnailFilename: "test_thumb.jpg",
            fileSize: 12345
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(FrameMetadata.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.hash, original.hash)
        XCTAssertEqual(decoded.filename, original.filename)
        XCTAssertEqual(decoded.thumbnailFilename, original.thumbnailFilename)
        XCTAssertEqual(decoded.fileSize, original.fileSize)
    }

    func testFrameManifestRoundTripsViaJSON() throws {
        var manifest = FrameManifest()
        manifest.frames.append(FrameMetadata(
            id: UUID(),
            timestamp: Date(),
            hash: 1,
            filename: "a.jpg",
            thumbnailFilename: "a_thumb.jpg",
            fileSize: 100
        ))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(FrameManifest.self, from: data)

        XCTAssertEqual(decoded.version, manifest.version)
        XCTAssertEqual(decoded.frames.count, 1)
        XCTAssertEqual(decoded.frames.first?.id, manifest.frames.first?.id)
    }

    // MARK: - RewindHistoryOption

    func testRewindHistoryOptionDurations() {
        XCTAssertEqual(RewindHistoryOption.thirtyMinutes.duration, 1800)
        XCTAssertEqual(RewindHistoryOption.twoHours.duration, 7200)
        XCTAssertEqual(RewindHistoryOption.eightHours.duration, 28800)
        XCTAssertEqual(RewindHistoryOption.twentyFourHours.duration, 86400)
    }

    func testResolvedReturnsDefaultForUnknownRawValue() {
        let option = RewindHistoryOption.resolved(from: 9999)
        XCTAssertEqual(option, .defaultValue)
    }

    func testResolvedReturnsCorrectForKnownRawValue() {
        let option = RewindHistoryOption.resolved(from: 1800)
        XCTAssertEqual(option, .thirtyMinutes)
    }

    func testAllCasesHaveNonEmptyLabels() {
        for option in RewindHistoryOption.allCases {
            XCTAssertFalse(option.settingsLabel.isEmpty)
            XCTAssertFalse(option.searchLabel.isEmpty)
            XCTAssertFalse(option.compactSearchLabel.isEmpty)
        }
    }
}
