import Foundation

struct OCRFrameQueue {
    private var frames: [StoredFrame] = []
    private var queuedFrameIDs: Set<UUID> = []
    private var shouldDequeueNewestFrame = true

    var count: Int {
        frames.count
    }

    var isEmpty: Bool {
        frames.isEmpty
    }

    @discardableResult
    mutating func enqueue(_ frame: StoredFrame) -> Bool {
        guard queuedFrameIDs.insert(frame.id).inserted else { return false }
        frames.append(frame)
        return true
    }

    mutating func enqueue<S: Sequence>(contentsOf incomingFrames: S) where S.Element == StoredFrame {
        for frame in incomingFrames {
            _ = enqueue(frame)
        }
    }

    mutating func clear() {
        frames.removeAll()
        queuedFrameIDs.removeAll()
        shouldDequeueNewestFrame = true
    }

    mutating func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        guard !frames.isEmpty else { return }

        frames.removeAll { ids.contains($0.id) }
        queuedFrameIDs.subtract(ids)
    }

    mutating func dequeue(limit: Int) -> [StoredFrame] {
        let safeLimit = max(limit, 1)
        var batch: [StoredFrame] = []
        batch.reserveCapacity(safeLimit)

        while batch.count < safeLimit, let frame = dequeueNext() {
            batch.append(frame)
        }

        return batch
    }

    private mutating func dequeueNext() -> StoredFrame? {
        guard !frames.isEmpty else { return nil }

        let frame: StoredFrame
        if shouldDequeueNewestFrame {
            frame = frames.removeLast()
        } else {
            frame = frames.removeFirst()
        }

        shouldDequeueNewestFrame.toggle()
        queuedFrameIDs.remove(frame.id)
        return frame
    }
}
