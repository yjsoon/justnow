import Dispatch
import Foundation

nonisolated protocol MemoryPressureEventSource: AnyObject, Sendable {
    func setEventHandler(_ handler: @escaping @Sendable (FrameMemoryPressureLevel) -> Void)
    func start()
    func cancel()
}

nonisolated final class DispatchMemoryPressureEventSource: MemoryPressureEventSource, @unchecked Sendable {
    private let source: DispatchSourceMemoryPressure
    private var handler: (@Sendable (FrameMemoryPressureLevel) -> Void)?
    private var didStart = false

    init(queue: DispatchQueue = DispatchQueue(label: "sg.tk.JustNow.memory-pressure")) {
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = self.source.data
            if event.contains(.critical) {
                self.handler?(.critical)
            } else if event.contains(.warning) {
                self.handler?(.warning)
            }
        }
    }

    func setEventHandler(_ handler: @escaping @Sendable (FrameMemoryPressureLevel) -> Void) {
        self.handler = handler
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        source.activate()
    }

    func cancel() {
        source.cancel()
    }
}

/// Serialises OS pressure callbacks on the main actor. Events which arrive
/// during active work are coalesced, with critical always taking precedence.
@MainActor
final class MemoryPressureMonitor {
    typealias Handler = @MainActor (FrameMemoryPressureLevel) async -> Void

    private let eventSource: any MemoryPressureEventSource
    private let handler: Handler
    private var pendingLevel: FrameMemoryPressureLevel?
    private var drainTask: Task<Void, Never>?
    private var drainGeneration: Int?
    private var isStarted = false
    private var lifecycleGeneration = 0

    init(
        eventSource: any MemoryPressureEventSource = DispatchMemoryPressureEventSource(),
        handler: @escaping Handler
    ) {
        self.eventSource = eventSource
        self.handler = handler
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        eventSource.setEventHandler { [weak self] level in
            guard let self else { return }
            Task { @MainActor [self] in
                self.enqueue(level, generation: generation)
            }
        }
        eventSource.start()
    }

    /// Fences callbacks from the cancelled lifecycle immediately, then waits
    /// for an already-running handler to return. Handler cancellation remains
    /// cooperative, so callers know no pressure work is still executing when
    /// this method completes even if the handler was suspended at cancellation.
    func cancel() async {
        let cancellation = beginCancellation()
        await cancellation.task?.value

        if drainGeneration == cancellation.drainGeneration {
            drainTask = nil
            drainGeneration = nil
        }
        if isStarted, pendingLevel != nil {
            startDrainIfNeeded()
        }
    }

    /// Synchronously installs the same lifecycle fence for termination paths
    /// which cannot await. Normal shutdown should call `cancel()` and await it.
    func cancelWithoutWaiting() {
        _ = beginCancellation()
    }

    private func beginCancellation() -> (task: Task<Void, Never>?, drainGeneration: Int?) {
        guard isStarted || drainTask != nil else { return (nil, nil) }
        isStarted = false
        lifecycleGeneration &+= 1
        pendingLevel = nil
        eventSource.cancel()
        let task = drainTask
        let generation = drainGeneration
        task?.cancel()
        return (task, generation)
    }

    private func enqueue(_ level: FrameMemoryPressureLevel, generation: Int) {
        guard isStarted, generation == lifecycleGeneration else { return }
        if level == .critical || pendingLevel == nil {
            pendingLevel = level
        }
        startDrainIfNeeded()
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil, pendingLevel != nil else { return }
        let generation = lifecycleGeneration
        drainGeneration = generation
        drainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                  self.isStarted,
                  self.lifecycleGeneration == generation,
                  let level = self.pendingLevel {
                self.pendingLevel = nil
                await self.handler(level)
            }
            guard self.drainGeneration == generation else { return }
            self.drainTask = nil
            self.drainGeneration = nil
            if self.isStarted,
               self.lifecycleGeneration == generation,
               self.pendingLevel != nil {
                self.startDrainIfNeeded()
            }
        }
    }
}
