import XCTest
@testable import JustNow

final class OCRFrameQueueTests: XCTestCase {
    func testEnqueueSkipsDuplicateFrameIDs() {
        let frame = makeFrame(secondsAgo: 1)
        var queue = OCRFrameQueue()

        XCTAssertTrue(queue.enqueue(frame))
        XCTAssertFalse(queue.enqueue(frame))
        XCTAssertEqual(queue.count, 1)
    }

    func testDequeueAlternatesBetweenNewestAndOldestFrames() {
        let frames = [
            makeFrame(secondsAgo: 4),
            makeFrame(secondsAgo: 3),
            makeFrame(secondsAgo: 2),
            makeFrame(secondsAgo: 1)
        ]
        var queue = OCRFrameQueue()
        queue.enqueue(contentsOf: frames)

        let dequeued = queue.dequeue(limit: 4)

        XCTAssertEqual(dequeued.map(\.id), [frames[3].id, frames[0].id, frames[2].id, frames[1].id])
        XCTAssertTrue(queue.isEmpty)
    }

    func testRemoveDropsQueuedFramesByID() {
        let frames = [
            makeFrame(secondsAgo: 3),
            makeFrame(secondsAgo: 2),
            makeFrame(secondsAgo: 1)
        ]
        var queue = OCRFrameQueue()
        queue.enqueue(contentsOf: frames)

        queue.remove(ids: [frames[1].id])

        XCTAssertEqual(queue.dequeue(limit: 2).map(\.id), [frames[2].id, frames[0].id])
    }

    func testClearResetsAlternatingDequeueOrder() {
        let initialFrames = [
            makeFrame(secondsAgo: 3),
            makeFrame(secondsAgo: 2),
            makeFrame(secondsAgo: 1)
        ]
        var queue = OCRFrameQueue()
        queue.enqueue(contentsOf: initialFrames)

        XCTAssertEqual(queue.dequeue(limit: 1).map(\.id), [initialFrames[2].id])

        queue.clear()

        let replacementFrames = [
            makeFrame(secondsAgo: 2),
            makeFrame(secondsAgo: 1)
        ]
        queue.enqueue(contentsOf: replacementFrames)

        XCTAssertEqual(queue.dequeue(limit: 2).map(\.id), [replacementFrames[1].id, replacementFrames[0].id])
    }

    private func makeFrame(secondsAgo: TimeInterval) -> StoredFrame {
        StoredFrame(
            id: UUID(),
            timestamp: Date().addingTimeInterval(-secondsAgo),
            hash: 0
        )
    }
}
