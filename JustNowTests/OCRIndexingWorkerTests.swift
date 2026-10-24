import XCTest
@testable import JustNow

final class OCRIndexingWorkerTests: XCTestCase {
    func testIndexSkipsFramesThatAlreadyHaveCachedText() async {
        let cachedFrame = makeFrame(secondsAgo: 2)
        let uncachedFrame = makeFrame(secondsAgo: 1)
        let probe = OCRIndexingWorkerProbe(cachedFrameIDs: [cachedFrame.id])
        let worker = OCRIndexingWorker(
            dependencies: OCRIndexingWorkerDependencies(
                hasCachedText: { frameID in
                    await probe.hasCachedText(frameID)
                },
                indexFrame: { frame in
                    let frameID = await MainActor.run { frame.id }
                    let shouldIndex = await probe.recordIndexAttempt(frameID: frameID)
                    guard shouldIndex else { return nil }

                    return OCRIndexedFrame(
                        frame: frame,
                        text: "OCR \(frameID.uuidString)",
                        duration: 0.05,
                        indexLag: 0.5
                    )
                }
            )
        )

        let indexedFrames = await worker.index(frames: [cachedFrame, uncachedFrame])

        XCTAssertEqual(indexedFrames.map(\.frame.id), [uncachedFrame.id])
        let indexedFrameIDs = await probe.indexedFrameIDs()
        XCTAssertEqual(indexedFrameIDs, [uncachedFrame.id])
    }

    func testIndexSkipsFramesWhoseDependencyReturnsNil() async {
        let failedFrame = makeFrame(secondsAgo: 2)
        let successfulFrame = makeFrame(secondsAgo: 1)
        let probe = OCRIndexingWorkerProbe(cachedFrameIDs: [], failingFrameIDs: [failedFrame.id])
        let worker = OCRIndexingWorker(
            dependencies: OCRIndexingWorkerDependencies(
                hasCachedText: { frameID in
                    await probe.hasCachedText(frameID)
                },
                indexFrame: { frame in
                    let frameID = await MainActor.run { frame.id }
                    let shouldIndex = await probe.recordIndexAttempt(frameID: frameID)
                    guard shouldIndex else { return nil }

                    return OCRIndexedFrame(
                        frame: frame,
                        text: "OCR \(frameID.uuidString)",
                        duration: 0.05,
                        indexLag: 0.5
                    )
                }
            )
        )

        let indexedFrames = await worker.index(frames: [failedFrame, successfulFrame])

        XCTAssertEqual(indexedFrames.map(\.frame.id), [successfulFrame.id])
    }

    private func makeFrame(secondsAgo: TimeInterval) -> StoredFrame {
        StoredFrame(
            id: UUID(),
            timestamp: Date().addingTimeInterval(-secondsAgo),
            hash: 0,
            displayID: nil,
            displayName: nil
        )
    }
}

private actor OCRIndexingWorkerProbe {
    private let cachedFrameIDs: Set<UUID>
    private let failingFrameIDs: Set<UUID>
    private var indexedFrameIDsStorage: [UUID] = []

    init(cachedFrameIDs: Set<UUID>, failingFrameIDs: Set<UUID> = []) {
        self.cachedFrameIDs = cachedFrameIDs
        self.failingFrameIDs = failingFrameIDs
    }

    func hasCachedText(_ frameID: UUID) -> Bool {
        cachedFrameIDs.contains(frameID)
    }

    func recordIndexAttempt(frameID: UUID) -> Bool {
        guard !failingFrameIDs.contains(frameID) else { return false }

        indexedFrameIDsStorage.append(frameID)
        return true
    }

    func indexedFrameIDs() -> [UUID] {
        indexedFrameIDsStorage
    }
}
