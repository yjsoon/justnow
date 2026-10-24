import CoreGraphics
import CoreText
import XCTest
@testable import JustNow

/// Runs real Vision OCR through the production index path on a synthetic
/// Retina capture. Normal-size UI text only survives indexing when the frame
/// is read at its captured resolution, so this guards against reintroducing a
/// downscaled decode.
final class OCRIndexResolutionTests: XCTestCase {
    private var directory: URL!

    private let words = [
        "synthetic", "quarterly", "invoice", "bluebird", "keyboard", "mortgage", "lantern", "wednesday",
        "elephant", "calendar", "permission", "tangerine", "harbour", "notebook", "velvet", "orchard"
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OCRIndexResolutionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testIndexingReadsTwelvePointTextOnARetinaCapture() async throws {
        // A 1512x982 pt screen (14-inch MacBook Pro default) captured at 2x.
        let image = try renderSyntheticScreen(pointWidth: 1512, pointHeight: 982, scale: 2, fontSize: 12)
        let jpegData = try XCTUnwrap(ImageEncoder.jpegData(from: image, quality: ImageEncoder.fullImageQuality))

        let store = try FrameStore(directory: directory.appendingPathComponent("frames-store", isDirectory: true))
        let capturedAt = Date()
        _ = try await store.beginCaptureSession(at: capturedAt.addingTimeInterval(-1))
        let frame = StoredFrame(id: UUID(), timestamp: capturedAt, hash: 1, displayID: nil, displayName: nil)
        let result = try await store.recordEncodedCapture(frame: frame, jpegData: jpegData, forceNewSpan: true)
        guard case .inserted = result.mutation else {
            return XCTFail("Expected the synthetic capture to be inserted, got \(result.mutation)")
        }

        let textCache = TextCache(directory: directory.appendingPathComponent("text-cache", isDirectory: true))
        let dependencies = OCRIndexingWorkerDependencies.live(
            frameRepository: DiskFrameRepository(frameStore: store),
            textCache: textCache
        )
        let indexedFrame = await dependencies.indexFrame(frame)
        let indexed = try XCTUnwrap(indexedFrame, "Expected OCR to index the frame")

        let recognised = indexed.text.lowercased()
        let found = words.filter { recognised.contains($0) }
        let missing = words.filter { !recognised.contains($0) }
        // The old 1200 px decode read none of these words; full resolution
        // reads all of them. Allow a margin for OCR model differences.
        XCTAssertGreaterThanOrEqual(found.count, 12, "OCR missed \(missing)")

        await textCache.setText(indexed.text, for: frame.id, timestamp: frame.timestamp)
        let matches = try await textCache.searchFrameIDs(matching: "synthetic", limit: 10)
        XCTAssertEqual(matches, [frame.id])
    }

    private func renderSyntheticScreen(
        pointWidth: Int,
        pointHeight: Int,
        scale: Int,
        fontSize: CGFloat
    ) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: pointWidth * scale,
            height: pointHeight * scale,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pointWidth * scale, height: pointHeight * scale))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

        let font = try XCTUnwrap(CTFontCreateUIFontForLanguage(.system, fontSize, nil))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        ]

        // Two columns of short lines, like a list or document window.
        var baseline = CGFloat(pointHeight) - 60
        for (index, word) in words.enumerated() {
            let text = "\(index + 1). The \(word) entry was updated by Alex at 10:4\(index % 10) today"
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            let x: CGFloat = index.isMultiple(of: 2) ? 40 : CGFloat(pointWidth) / 2 + 20
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, context)
            if !index.isMultiple(of: 2) { baseline -= fontSize * 2.2 }
        }

        return try XCTUnwrap(context.makeImage())
    }
}
