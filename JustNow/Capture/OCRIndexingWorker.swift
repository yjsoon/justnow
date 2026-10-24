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
    let indexFrame: @Sendable (StoredFrame) async -> OCRIndexedFrame?

    static func live(
        frameRepository: any FrameRepository,
        textCache: TextCache
    ) -> OCRIndexingWorkerDependencies {
        OCRIndexingWorkerDependencies(
            hasCachedText: { frameID in
                await textCache.hasCachedText(for: frameID)
            },
            indexFrame: { frame in
                let startedAt = Date()

                do {
                    // Index at the captured resolution. Fast OCR needs about
                    // two pixels per point to read normal-size UI text, and
                    // any downscaled decode loses it on Retina captures.
                    let image = try await frameRepository.loadFullImage(id: frame.id)
                    let text = await TextRecognitionManager.extractText(from: image, mode: .searchIndex)
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

    func index(frames: [StoredFrame]) async -> [OCRIndexedFrame] {
        return await withTaskGroup(of: OCRIndexedFrame?.self, returning: [OCRIndexedFrame].self) { group in
            for frame in frames {
                group.addTask {
                    guard !(await dependencies.hasCachedText(frame.id)) else { return nil }
                    return await dependencies.indexFrame(frame)
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
