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
    private var isStarted = false

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
        eventSource.setEventHandler { [weak self] level in
            guard let self else { return }
            Task { @MainActor [self] in
                self.enqueue(level)
            }
        }
        eventSource.start()
    }

    func cancel() {
        guard isStarted else { return }
        isStarted = false
        pendingLevel = nil
        drainTask?.cancel()
        drainTask = nil
        eventSource.cancel()
    }

    private func enqueue(_ level: FrameMemoryPressureLevel) {
        guard isStarted else { return }
        if level == .critical || pendingLevel == nil {
            pendingLevel = level
        }
        startDrainIfNeeded()
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil, pendingLevel != nil else { return }
        drainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.isStarted, let level = self.pendingLevel {
                self.pendingLevel = nil
                await self.handler(level)
            }
            self.drainTask = nil
            if self.isStarted, self.pendingLevel != nil {
                self.startDrainIfNeeded()
            }
        }
    }
}
