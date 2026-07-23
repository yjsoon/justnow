import Foundation

/// Serialises coordinator lifecycle work across suspension points. Main-actor
/// isolation alone does not prevent another task from entering while an
/// operation awaits ScreenCaptureKit.
@MainActor
final class CaptureReconciliationGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var isHeld = false
    private var waiters: [Waiter] = []

    func withPermit<T>(
        _ operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        guard await acquireUnlessCancelled() else { throw CancellationError() }
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    func withPermitIgnoringCancellation<T>(
        _ operation: @escaping @MainActor () async -> T
    ) async -> T {
        await acquireIgnoringCancellation()
        defer { release() }
        return await operation()
    }

    private func acquireUnlessCancelled() async -> Bool {
        guard isHeld else {
            guard !Task.isCancelled else { return false }
            isHeld = true
            return true
        }

        let id = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(id: id)
            }
        })
    }

    private func acquireIgnoringCancellation() async {
        guard isHeld else {
            isHeld = true
            return
        }
        _ = await withCheckedContinuation { continuation in
            waiters.append(Waiter(id: UUID(), continuation: continuation))
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().continuation.resume(returning: true)
    }

#if DEBUG
    var queuedWaiterCountForTesting: Int { waiters.count }
#endif
}
