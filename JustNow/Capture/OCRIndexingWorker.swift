import CoreGraphics
import Foundation

struct OCRIndexedFrame: Sendable {
    let frame: StoredFrame
    let text: String
    let duration: TimeInterval
    let indexLag: TimeInterval
}

struct OCRIndexingWorkerDependencies: Sendable {
    let hasCachedText: @Sendable (UUID) async -> Bool
    let indexFrame: @Sendable (StoredFrame, Int) async -> OCRIndexedFrame?

    static func live(frameStore: FrameStore, textCache: TextCache) -> OCRIndexingWorkerDependencies {
        OCRIndexingWorkerDependencies(
            hasCachedText: { frameID in
                await textCache.hasCachedText(for: frameID)
            },
            indexFrame: { frame, imageMaxPixelSize in
                let startedAt = Date()

                do {
                    let image: CGImage
                    if imageMaxPixelSize > 0 {
                        image = try await frameStore.loadSearchIndexImage(
                            id: frame.id,
                            maxPixelSize: imageMaxPixelSize
                        )
                    } else {
                        image = try await frameStore.loadFullImage(id: frame.id)
                    }

                    let text = await TextRecognitionManager.extractText(from: image)
                    guard !Task.isCancelled else { return nil }

                    return OCRIndexedFrame(
                        frame: frame,
                        text: text,
                        duration: Date().timeIntervalSince(startedAt),
                        indexLag: Date().timeIntervalSince(frame.timestamp)
                    )
                } catch {
                    return nil
                }
            }
        )
    }
}

struct OCRIndexingWorker {
    private let dependencies: OCRIndexingWorkerDependencies

    init(dependencies: OCRIndexingWorkerDependencies) {
        self.dependencies = dependencies
    }

    func index(frames: [StoredFrame], searchImageMaxPixelSize: Int) async -> [OCRIndexedFrame] {
        return await withTaskGroup(of: OCRIndexedFrame?.self, returning: [OCRIndexedFrame].self) { group in
            for frame in frames {
                group.addTask {
                    guard !(await dependencies.hasCachedText(frame.id)) else { return nil }
                    return await dependencies.indexFrame(frame, searchImageMaxPixelSize)
                }
            }

            var indexedFrames: [OCRIndexedFrame] = []
            for await result in group {
                guard !Task.isCancelled else { return indexedFrames }
                if let result {
                    indexedFrames.append(result)
                }
            }

            return indexedFrames
        }
    }
}
