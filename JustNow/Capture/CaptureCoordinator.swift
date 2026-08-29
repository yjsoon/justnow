//
//  CaptureCoordinator.swift
//  JustNow
//

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import os.log

private let captureLogger = Logger(subsystem: "sg.tk.JustNow", category: "Capture")

enum CaptureCoordinatorStartReadiness: Equatable {
    case ready
    case coolingDown(untilMonotonicTime: TimeInterval)
    case noDisplay
}

nonisolated enum CaptureLogicalSessionTransition: Equatable {
    case begin
    case end
    case none
}

enum CaptureCoordinatorSessionError: Error {
    case missingDelegate
    case missingFrameBuffer
}

nonisolated enum CaptureBackgroundReconcileRecoveryAction: Equatable {
    case none
    case notifyPermissionFlow
    case retryAfterCooldown
    case retryFallback
}

/// Owns the cancellable timer used to retry capture after a broker cooldown.
/// Keeping the timer bookkeeping separate makes replacement and re-entrant
/// rescheduling deterministic without pulling ScreenCaptureKit into tests.
@MainActor
final class CaptureCooldownRestartScheduler {
    typealias Sleep = @MainActor (Duration) async throws -> Void

    private let sleep: Sleep
    private var task: Task<Void, Never>?
    private var generation = 0
    private(set) var scheduledDeadline: TimeInterval?

    init(sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    func schedule(
        deadline: TimeInterval,
        delay: Duration,
        retry: @escaping @MainActor () async -> Void
    ) {
        guard scheduledDeadline != deadline else { return }

        task?.cancel()
        scheduledDeadline = deadline
        generation += 1
        let taskGeneration = generation
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            // A retry may synchronously schedule its replacement. Clear the
            // current deadline first so even an identical new deadline can be
            // registered, and let the generation guard protect that new state.
            self.scheduledDeadline = nil
            defer {
                if self.generation == taskGeneration {
                    self.task = nil
                    self.scheduledDeadline = nil
                }
            }
            await retry()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        scheduledDeadline = nil
        generation += 1
    }
}

@MainActor
protocol CaptureCoordinatorDelegate: AnyObject {
    func captureCoordinator(
        _ coordinator: CaptureCoordinator,
        didCaptureFrame image: CGImage,
        at timestamp: Date,
        from display: DisplayInfo
    )
    func captureCoordinatorDidStopUnexpectedly(_ coordinator: CaptureCoordinator)
    func captureCoordinatorDidBeginCaptureSession(_ coordinator: CaptureCoordinator) async throws
    func captureCoordinator(
        _ coordinator: CaptureCoordinator,
        didEndCaptureSession reason: CaptureSessionEndReason
    ) async throws
    func captureCoordinatorDidUpdateDisplays(_ coordinator: CaptureCoordinator)
    func captureCoordinator(
        _ coordinator: CaptureCoordinator,
        didChangeRecoveryState state: CaptureRequestBrokerRecoveryState
    )
}

extension CaptureCoordinatorDelegate {
    func captureCoordinatorDidBeginCaptureSession(_ coordinator: CaptureCoordinator) async throws {}
    func captureCoordinator(
        _ coordinator: CaptureCoordinator,
        didEndCaptureSession reason: CaptureSessionEndReason
    ) async throws {}
    func captureCoordinatorDidUpdateDisplays(_ coordinator: CaptureCoordinator) {}
    func captureCoordinator(
        _ coordinator: CaptureCoordinator,
        didChangeRecoveryState state: CaptureRequestBrokerRecoveryState
    ) {}
}

/// Owns one ScreenCaptureManager per physical display and fans capture
/// lifecycle across them. Hot-plug is handled via the AppKit screen
/// parameters notification.
@MainActor
final class CaptureCoordinator: NSObject, ScreenCaptureDelegate {
    typealias DisplayDiscovery = @MainActor () async throws -> [DisplayInfo]
    typealias CaptureManagerFactory = @MainActor (CGDirectDisplayID, CaptureRequestBroker) -> ScreenCaptureManager

    private struct ManagedDisplay {
        let info: DisplayInfo
        let manager: ScreenCaptureManager
    }

    weak var delegate: CaptureCoordinatorDelegate?

    /// All display managers share one broker so a ScreenCaptureKit false TCC
    /// denial pauses the whole process before another display can retry.
    private let captureRequestBroker: CaptureRequestBroker
    private let hasScreenRecordingPermission: @MainActor () -> Bool
    private let discoverDisplays: DisplayDiscovery
    private let makeCaptureManager: CaptureManagerFactory
    /// Owner token for the coordinator's own brokered content-discovery calls.
    private let reconcileRequestOwner = UUID()
    private var managed: [UUID: ManagedDisplay] = [:]
    private var captureInterval: TimeInterval = 1.0
    private var captureScale: Int = 2
    private var isRunning = false
    private var screenParamsObserver: NSObjectProtocol?
    private var reconcileTask: Task<Void, Never>?
    private var reconcileTaskGeneration = 0
    private let reconciliationGate = CaptureReconciliationGate()
    /// Logical history-session ownership is independent of manager flags: a
    /// manager clears `isCapturing` before its stop callback, and display
    /// replacement can temporarily leave no live manager inside one reconcile.
    private var logicalSessionGeneration = 0
    private var activeLogicalSessionGeneration: Int?
    /// Broker recovery can occur midway through display discovery/startup.
    /// Suppress that intermediate healthy signal until the full reconciliation
    /// confirms capture is live and the circuit stayed closed.
    private var activeReconciliationCount = 0
    private var fallbackRestartToken: TimeInterval = -1
    /// Retries display reconciliation shortly after the shared circuit's
    /// cooldown expires, so a restart blocked mid-episode is not stranded in
    /// "Stopped" until the next unrelated system event.
    private let cooldownRestartScheduler: CaptureCooldownRestartScheduler

    override convenience init() {
        let broker = CaptureRequestBroker(persistence: UserDefaultsCaptureCircuitStore())
        self.init(
            captureRequestBroker: broker,
            cooldownRestartScheduler: CaptureCooldownRestartScheduler(),
            hasScreenRecordingPermission: { ScreenCaptureManager.hasScreenRecordingPermission() },
            discoverDisplays: {
                let content = try await ScreenshotCaptureExecution.run {
                    try await SCShareableContent.excludingDesktopWindows(
                        false,
                        onScreenWindowsOnly: true
                    )
                }
                return content.displays.map { DisplayIdentity.info(for: $0) }
            },
            makeCaptureManager: { displayID, broker in
                ScreenCaptureManager(
                    targetDisplayID: displayID,
                    captureRequestBroker: broker
                )
            },
            observeScreenChanges: true
        )
    }

    init(
        captureRequestBroker: CaptureRequestBroker,
        cooldownRestartScheduler: CaptureCooldownRestartScheduler,
        hasScreenRecordingPermission: @escaping @MainActor () -> Bool,
        discoverDisplays: @escaping DisplayDiscovery,
        makeCaptureManager: @escaping CaptureManagerFactory,
        observeScreenChanges: Bool
    ) {
        self.captureRequestBroker = captureRequestBroker
        self.cooldownRestartScheduler = cooldownRestartScheduler
        self.hasScreenRecordingPermission = hasScreenRecordingPermission
        self.discoverDisplays = discoverDisplays
        self.makeCaptureManager = makeCaptureManager
        super.init()
        captureRequestBroker.recoveryStateDidChange = { [weak self] state in
            // Sleep, lock, overlay and user-pause flows mark the coordinator
            // stopped before awaiting an in-flight ScreenCaptureKit request.
            // Do not let a late broker result overwrite those more specific
            // menu states.
            guard let self, self.isRunning else { return }
            guard Self.shouldForwardBrokerRecoveryState(
                state,
                activeReconciliationCount: self.activeReconciliationCount
            ) else { return }
            self.delegate?.captureCoordinator(self, didChangeRecoveryState: state)
        }
        if observeScreenChanges {
            screenParamsObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleReconcile()
                }
            }
        }
    }

    deinit {
        if let observer = screenParamsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var isCapturing: Bool {
        managed.values.contains { $0.manager.isCapturing }
    }

    var activeDisplays: [DisplayInfo] {
        managed.values
            .map(\.info)
            .sorted { lhs, rhs in
                // Built-in first, then alphabetical by name — keeps the UI ordering stable.
                let lBuiltIn = lhs.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
                let rBuiltIn = rhs.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
                if lBuiltIn != rBuiltIn { return lBuiltIn }
                return lhs.name < rhs.name
            }
    }

    var isCaptureCircuitCoolingDown: Bool {
        captureRequestBroker.openCircuitMonotonicDeadline != nil
    }

    func startCapture() async throws {
        isRunning = true
        try await reconcileDisplays(startNewManagers: true)
        switch Self.startReadiness(
            isCapturing: isCapturing,
            openCircuitDeadline: captureRequestBroker.openCircuitMonotonicDeadline
        ) {
        case .ready:
            return
        case .coolingDown(let deadline):
            throw CaptureRequestBrokerError.cooldown(untilMonotonicTime: deadline)
        case .noDisplay:
            scheduleFallbackRestart()
            throw CaptureError.noDisplay
        }
    }

    nonisolated static func startReadiness(
        isCapturing: Bool,
        openCircuitDeadline: TimeInterval?
    ) -> CaptureCoordinatorStartReadiness {
        if let openCircuitDeadline {
            return .coolingDown(untilMonotonicTime: openCircuitDeadline)
        }
        return isCapturing ? .ready : .noDisplay
    }

    nonisolated static func shouldForwardBrokerRecoveryState(
        _ state: CaptureRequestBrokerRecoveryState,
        activeReconciliationCount: Int
    ) -> Bool {
        state != .normal || activeReconciliationCount == 0
    }

    nonisolated static func shouldPublishReconciledReadiness(
        isRunning: Bool,
        isCapturing: Bool,
        isCircuitClosed: Bool
    ) -> Bool {
        isRunning && isCapturing && isCircuitClosed
    }

    /// ScreenCaptureManager clears its own `isCapturing` flag before reporting
    /// an unexpected stop. Session ownership therefore depends only on whether
    /// another managed display remains live after the stopped manager is removed.
    nonisolated static func shouldEndSessionAfterManagedManagerStops(
        remainingManagerCaptureStates: [Bool]
    ) -> Bool {
        !remainingManagerCaptureStates.contains(true)
    }

    nonisolated static func logicalSessionTransition(
        hasActiveLogicalSession: Bool,
        hasCapturingManager: Bool
    ) -> CaptureLogicalSessionTransition {
        switch (hasActiveLogicalSession, hasCapturingManager) {
        case (false, true): .begin
        case (true, false): .end
        default: .none
        }
    }

    nonisolated static func backgroundReconcileRecoveryAction(
        isRunning: Bool,
        isCapturing: Bool,
        errorIsCancellation: Bool,
        errorIsPermissionDenied: Bool,
        hasOpenCircuit: Bool
    ) -> CaptureBackgroundReconcileRecoveryAction {
        guard isRunning, !errorIsCancellation else { return .none }
        if hasOpenCircuit { return .retryAfterCooldown }
        if errorIsPermissionDenied { return .notifyPermissionFlow }
        return isCapturing ? .none : .retryFallback
    }

    func stopCapture(reason: CaptureSessionEndReason = .paused) async {
        isRunning = false
        reconcileTaskGeneration += 1
        reconcileTask?.cancel()
        reconcileTask = nil
        cancelCooldownRestart()
        await reconciliationGate.withPermitIgnoringCancellation { [self] in
            let snapshot = Array(managed.values)
            managed.removeAll()
            let previousLoops = snapshot.map { $0.manager.beginStoppingCapture() }
            for previousLoop in previousLoops {
                await previousLoop?.value
            }
            await endLogicalCaptureSessionIfNeeded(reason: reason)
        }
        delegate?.captureCoordinatorDidUpdateDisplays(self)
    }

    func updateCaptureInterval(_ interval: TimeInterval) {
        captureInterval = interval
        for entry in managed.values {
            entry.manager.updateCaptureInterval(interval)
        }
    }

    func updateCaptureScale(_ scale: Int) {
        captureScale = scale
        for entry in managed.values {
            entry.manager.updateCaptureScale(scale)
        }
    }

    /// One-shot capture for a specific display. Used when opening the overlay
    /// so the freshest frame lands in the buffer.
    func captureNow(displayID: UUID) async -> (image: CGImage, display: DisplayInfo)? {
        guard let entry = managed[displayID] else { return nil }
        guard let image = await entry.manager.captureNow() else { return nil }
        return (image, entry.info)
    }

    func display(forDisplayID displayID: CGDirectDisplayID) -> DisplayInfo? {
        managed.values.first(where: { $0.info.displayID == displayID })?.info
    }

    // MARK: - Hot-plug

    func scheduleReconcile() {
        guard isRunning else { return }
        reconcileTaskGeneration += 1
        let generation = reconcileTaskGeneration
        reconcileTask?.cancel()
        reconcileTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == self.reconcileTaskGeneration {
                    self.reconcileTask = nil
                }
            }
            do {
                try await self.reconcileDisplays(startNewManagers: true)
                if !self.isCapturing {
                    DiagnosticsLog.shared.log(
                        "Capture",
                        "Display reconciliation completed without active capture; scheduling fallback retry"
                    )
                    self.scheduleFallbackRestart()
                }
            } catch {
                let isPermissionDenied: Bool
                if case CaptureError.permissionDenied = error {
                    isPermissionDenied = true
                } else {
                    isPermissionDenied = false
                }
                switch Self.backgroundReconcileRecoveryAction(
                    isRunning: self.isRunning,
                    isCapturing: self.isCapturing,
                    errorIsCancellation: error is CancellationError,
                    errorIsPermissionDenied: isPermissionDenied,
                    hasOpenCircuit: self.captureRequestBroker.openCircuitMonotonicDeadline != nil
                ) {
                case .notifyPermissionFlow:
                    // A revocation found during a system-event reconcile must
                    // reach the app's restart/permission flow, not vanish.
                    self.delegate?.captureCoordinatorDidStopUnexpectedly(self)
                case .retryAfterCooldown:
                    self.scheduleCooldownRestart()
                case .retryFallback:
                    let detail = DiagnosticsLogFormat.describe(error)
                    captureLogger.error("Display reconciliation failed; scheduling fallback retry: \(detail, privacy: .public)")
                    DiagnosticsLog.shared.log(
                        "Capture",
                        "Display reconciliation failed; scheduling fallback retry: \(detail)"
                    )
                    self.scheduleFallbackRestart()
                case .none:
                    break
                }
            }
        }
    }

    private func reconcileDisplays(startNewManagers: Bool) async throws {
        try await reconciliationGate.withPermit { [self] in
            guard isRunning, !Task.isCancelled else { throw CancellationError() }
            try await reconcileDisplaysWithPermit(startNewManagers: startNewManagers)
        }
    }

    private func reconcileDisplaysWithPermit(startNewManagers: Bool) async throws {
        var managersStartedThisPass: [UUID] = []
        activeReconciliationCount += 1
        defer { activeReconciliationCount -= 1 }

        // A false ScreenCaptureKit denial can flap preflight to denied for a
        // few seconds. If the shared circuit is already open, do not treat
        // that as a real revoke or we show the permission alert and the user
        // quits, which wipes the in-memory cooldown.
        switch CapturePermissionGate.resolve(
            hasPermission: hasScreenRecordingPermission(),
            circuitIsOpen: captureRequestBroker.openCircuitMonotonicDeadline != nil
        ) {
        case .allowed:
            break
        case .coolingDown:
            if let deadline = captureRequestBroker.openCircuitMonotonicDeadline {
                scheduleCooldownRestart()
                throw CaptureRequestBrokerError.cooldown(untilMonotonicTime: deadline)
            }
            throw CaptureError.permissionDenied
        case .denied:
            throw CaptureError.permissionDenied
        }
        let discoveredDisplays: [DisplayInfo]
        do {
            // Brokered so reconcile and restart respect the shared circuit:
            // while it is cooling down after a false TCC denial, no code path
            // may touch ScreenCaptureKit and risk another native prompt.
            discoveredDisplays = try await captureRequestBroker.perform(owner: reconcileRequestOwner) {
                try await self.discoverDisplays()
            }
        } catch {
            if CaptureFailureRecovery.isPermissionDenial(error) {
                switch CapturePermissionGate.resolve(
                    hasPermission: hasScreenRecordingPermission(),
                    circuitIsOpen: captureRequestBroker.openCircuitMonotonicDeadline != nil
                ) {
                case .denied:
                    throw CaptureError.permissionDenied
                case .coolingDown:
                    if let deadline = captureRequestBroker.openCircuitMonotonicDeadline {
                        scheduleCooldownRestart()
                        throw CaptureRequestBrokerError.cooldown(untilMonotonicTime: deadline)
                    }
                    throw CaptureError.permissionDenied
                case .allowed:
                    break
                }
            }
            if !(error is CancellationError),
               let deadline = captureRequestBroker.openCircuitMonotonicDeadline {
                scheduleCooldownRestart()
                throw CaptureRequestBrokerError.cooldown(untilMonotonicTime: deadline)
            }
            throw error
        }
        try Task.checkCancellation()
        guard isRunning else { throw CancellationError() }

        var desired: [UUID: DisplayInfo] = [:]
        for info in discoveredDisplays {
            desired[info.id] = info
        }

        // Remove managers for displays that are no longer connected.
        let removedIDs = managed.keys.filter { desired[$0] == nil }
        let removedEntries = removedIDs.compactMap { managed.removeValue(forKey: $0) }
        let previousLoops = removedEntries.map { $0.manager.beginStoppingCapture() }
        for (entry, previousLoop) in zip(removedEntries, previousLoops) {
            await previousLoop?.value
            guard isRunning, !Task.isCancelled else { throw CancellationError() }
            captureLogger.info("Capture stopped for removed display: \(entry.info.name, privacy: .public)")
            DiagnosticsLog.shared.log("Capture", "Capture stopped for removed display: \(entry.info.name)")
        }

        do {
            // Start managers for newly seen displays. Sorting makes both
            // startup and transactional rollback deterministic.
            if startNewManagers {
                for (id, info) in desired.sorted(by: { $0.key.uuidString < $1.key.uuidString })
                    where managed[id] == nil {
                    guard let physicalDisplayID = info.displayID else { continue }
                    let manager = makeCaptureManager(physicalDisplayID, captureRequestBroker)
                    manager.delegate = self
                    manager.updateCaptureInterval(captureInterval)
                    manager.updateCaptureScale(captureScale)
                    managed[id] = ManagedDisplay(info: info, manager: manager)
                    do {
                        try await manager.startCapture()
                        guard isRunning, !Task.isCancelled else {
                            if managed[id]?.manager === manager {
                                managed.removeValue(forKey: id)
                            }
                            let previousLoop = manager.beginStoppingCapture()
                            await previousLoop?.value
                            throw CancellationError()
                        }
                        captureLogger.info("Capture started for display: \(info.name, privacy: .public)")
                        DiagnosticsLog.shared.log("Capture", "Capture started for display: \(info.name)")
                        managersStartedThisPass.append(id)
                    } catch {
                        if managed[id]?.manager === manager {
                            managed.removeValue(forKey: id)
                        }
                        guard isRunning, !Task.isCancelled else { throw CancellationError() }
                        let isPermissionDenied: Bool
                        if case CaptureError.permissionDenied = error {
                            isPermissionDenied = true
                        } else {
                            isPermissionDenied = false
                        }
                        // A genuine permission denial must never be downgraded to
                        // a cooldown deferral, even if a circuit from an earlier
                        // false-denial episode happens to be open.
                        if !isPermissionDenied,
                           !(error is CancellationError),
                           captureRequestBroker.openCircuitMonotonicDeadline != nil {
                            // The shared circuit opened (or was already open); the
                            // broker has logged it. Defer this display to the
                            // cooldown restart instead of counting a hard failure.
                            scheduleCooldownRestart()
                            continue
                        }
                        let detail = DiagnosticsLogFormat.describe(error)
                        captureLogger.error("Failed to start capture for \(info.name, privacy: .public): \(detail, privacy: .public)")
                        DiagnosticsLog.shared.log(
                            "Capture",
                            "Failed to start capture for \(info.name): \(detail); \(CaptureSystemState.summary())"
                        )
                        if isPermissionDenied {
                            throw error
                        }
                        if !(error is CancellationError) {
                            DiagnosticsLog.shared.log(
                                "Capture",
                                "Display start failed without an active cooldown; scheduling fallback reconciliation"
                            )
                            scheduleFallbackRestart(evenIfPartiallyCapturing: true)
                        }
                    }
                }
            }

            try await reconcileLogicalCaptureSessionState()
        } catch {
            // Any fatal error in a later display start or durable logical
            // begin rolls back every manager installed in this pass.
            let startedEntries = managersStartedThisPass.compactMap { id -> ManagedDisplay? in
                guard let entry = managed[id] else { return nil }
                managed.removeValue(forKey: id)
                return entry
            }
            let previousLoops = startedEntries.map { $0.manager.beginStoppingCapture() }
            for previousLoop in previousLoops {
                await previousLoop?.value
            }
            delegate?.captureCoordinatorDidUpdateDisplays(self)
            throw error
        }

        delegate?.captureCoordinatorDidUpdateDisplays(self)
        if Self.shouldPublishReconciledReadiness(
            isRunning: isRunning,
            isCapturing: isCapturing,
            isCircuitClosed: captureRequestBroker.isCircuitClosed
        ) {
            // This is the authoritative ready signal. A broker half-open probe
            // may report healthy earlier, before every missing display starts.
            delegate?.captureCoordinator(self, didChangeRecoveryState: .normal)
        }
    }

    private func reconcileLogicalCaptureSessionState() async throws {
        switch Self.logicalSessionTransition(
            hasActiveLogicalSession: activeLogicalSessionGeneration != nil,
            hasCapturingManager: isCapturing
        ) {
        case .begin:
            guard let delegate else {
                throw CaptureCoordinatorSessionError.missingDelegate
            }
            logicalSessionGeneration += 1
            let generation = logicalSessionGeneration
            do {
                try await delegate.captureCoordinatorDidBeginCaptureSession(self)
                activeLogicalSessionGeneration = generation
            } catch {
                activeLogicalSessionGeneration = nil
                throw error
            }
        case .end:
            await endLogicalCaptureSessionIfNeeded(reason: .unexpectedStop)
        case .none:
            break
        }
    }

    private func endLogicalCaptureSessionIfNeeded(reason: CaptureSessionEndReason) async {
        guard activeLogicalSessionGeneration != nil else { return }
        // Clear first so a failed durable close cannot cause duplicate end
        // publication; FrameBuffer retains that close for retry before begin.
        activeLogicalSessionGeneration = nil
        do {
            try await delegate?.captureCoordinator(self, didEndCaptureSession: reason)
        } catch {
            let detail = DiagnosticsLogFormat.describe(error)
            captureLogger.error("Failed to close capture history session: \(detail, privacy: .public)")
            DiagnosticsLog.shared.log("Capture", "Failed to close capture history session: \(detail)")
        }
    }

    // MARK: - Cooldown restart

    /// Schedules one reconcile pass shortly after the shared circuit's
    /// cooldown expires. Bounded by design: if the retry's probe fails again,
    /// the broker reopens the circuit with an escalated cooldown and this
    /// reschedules for the new, later deadline.
    private func scheduleCooldownRestart() {
        guard isRunning else { return }
        guard let deadline = captureRequestBroker.openCircuitMonotonicDeadline,
              let remaining = captureRequestBroker.remainingCooldown() else { return }
        guard cooldownRestartScheduler.scheduledDeadline != deadline else { return }

        let delay = remaining + 1
        DiagnosticsLog.shared.log(
            "Capture",
            "Capture start deferred; retrying in \(Int(delay)) seconds when the shared ScreenCaptureKit circuit cooldown ends"
        )
        scheduleCaptureRestart(deadline: deadline, delay: .seconds(delay))
    }

    private func scheduleFallbackRestart(evenIfPartiallyCapturing: Bool = false) {
        guard isRunning, evenIfPartiallyCapturing || !isCapturing else { return }
        fallbackRestartToken -= 1
        let delay = CaptureFailureRecovery.falsePermissionDenialDelay
        DiagnosticsLog.shared.log(
            "Capture",
            "Capture recovery found no usable display; retrying reconciliation in \(Int(delay)) seconds"
        )
        scheduleCaptureRestart(
            deadline: fallbackRestartToken,
            delay: .seconds(delay)
        )
    }

    private func scheduleCaptureRestart(deadline: TimeInterval, delay: Duration) {
        cooldownRestartScheduler.schedule(deadline: deadline, delay: delay) { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, self.isRunning else { return }
            do {
                try await self.reconcileDisplays(startNewManagers: true)
                guard self.isRunning, !Task.isCancelled else { return }
                if !self.isCapturing {
                    self.scheduleFallbackRestart()
                }
            } catch {
                guard self.isRunning, !(error is CancellationError) else { return }
                if case CaptureError.permissionDenied = error {
                    // A real revocation discovered during a background retry
                    // must reach the app's restart/permission flow instead of
                    // being silently dropped.
                    DiagnosticsLog.shared.log(
                        "Capture",
                        "Cooldown restart found screen recording permission revoked; \(CaptureSystemState.summary())"
                    )
                    self.delegate?.captureCoordinatorDidStopUnexpectedly(self)
                } else if self.captureRequestBroker.openCircuitMonotonicDeadline == nil {
                    self.scheduleFallbackRestart()
                }
                // Cooldown failures already rescheduled another restart from
                // inside reconcileDisplays.
            }
        }
    }

    private func cancelCooldownRestart() {
        cooldownRestartScheduler.cancel()
    }

    // MARK: - ScreenCaptureDelegate

    func captureManager(_ manager: ScreenCaptureManager, didCaptureFrame image: CGImage, at timestamp: Date) {
        guard let entry = managed.values.first(where: { $0.manager === manager }) else { return }
        delegate?.captureCoordinator(self, didCaptureFrame: image, at: timestamp, from: entry.info)
    }

    func captureManagerDidStop(_ manager: ScreenCaptureManager) {
        guard isRunning else { return }
        guard managed.values.contains(where: { $0.manager === manager }) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reconciliationGate.withPermitIgnoringCancellation {
                guard self.isRunning,
                      let stopped = self.managed.first(where: { $0.value.manager === manager }) else {
                    return
                }
                self.managed.removeValue(forKey: stopped.key)
                self.delegate?.captureCoordinatorDidUpdateDisplays(self)

                // Membership and aggregate state are authoritative only under
                // the gate. This also lets a callback queued while durable
                // begin was suspended close the session that begin publishes
                // before the callback acquires the gate. A removed/replaced
                // old manager fails the membership check above.
                if Self.shouldEndSessionAfterManagedManagerStops(
                       remainingManagerCaptureStates: self.managed.values.map {
                           $0.manager.isCapturing
                       }
                   ) {
                    await self.endLogicalCaptureSessionIfNeeded(reason: .unexpectedStop)
                }
                guard self.isRunning else { return }
                self.delegate?.captureCoordinatorDidStopUnexpectedly(self)
            }
        }
    }
}
