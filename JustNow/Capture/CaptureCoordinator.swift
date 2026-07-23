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

@MainActor
protocol CaptureCoordinatorDelegate: AnyObject {
    func captureCoordinator(
        _ coordinator: CaptureCoordinator,
        didCaptureFrame image: CGImage,
        at timestamp: Date,
        from display: DisplayInfo
    )
    func captureCoordinatorDidStopUnexpectedly(_ coordinator: CaptureCoordinator)
    func captureCoordinatorDidUpdateDisplays(_ coordinator: CaptureCoordinator)
    func captureCoordinator(
        _ coordinator: CaptureCoordinator,
        didChangeRecoveryState state: CaptureRequestBrokerRecoveryState
    )
}

extension CaptureCoordinatorDelegate {
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
    private struct ManagedDisplay {
        let info: DisplayInfo
        let manager: ScreenCaptureManager
    }

    weak var delegate: CaptureCoordinatorDelegate?

    /// All display managers share one broker so a ScreenCaptureKit false TCC
    /// denial pauses the whole process before another display can retry.
    private let captureRequestBroker: CaptureRequestBroker
    /// Owner token for the coordinator's own brokered content-discovery calls.
    private let reconcileRequestOwner = UUID()
    private var managed: [UUID: ManagedDisplay] = [:]
    private var captureInterval: TimeInterval = 1.0
    private var captureScale: Int = 2
    private var isRunning = false
    private var screenParamsObserver: NSObjectProtocol?
    private var reconcileTask: Task<Void, Never>?
    /// Retries display reconciliation shortly after the shared circuit's
    /// cooldown expires, so a restart blocked mid-episode is not stranded in
    /// "Stopped" until the next unrelated system event.
    private var cooldownRestartTask: Task<Void, Never>?
    private var cooldownRestartDeadline: TimeInterval?
    /// Identifies the current restart so a finished task only clears state it
    /// still owns, even when a reopened circuit scheduled a replacement while
    /// the task was reconciling.
    private var cooldownRestartGeneration = 0

    override init() {
        let captureRequestBroker = CaptureRequestBroker()
        self.captureRequestBroker = captureRequestBroker
        super.init()
        captureRequestBroker.recoveryStateDidChange = { [weak self] state in
            // Sleep, lock, overlay and user-pause flows mark the coordinator
            // stopped before awaiting an in-flight ScreenCaptureKit request.
            // Do not let a late broker result overwrite those more specific
            // menu states.
            guard let self, self.isRunning else { return }
            self.delegate?.captureCoordinator(self, didChangeRecoveryState: state)
        }
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
            // A process-wide cooldown blocks every display, including managers
            // that started earlier in this reconciliation pass. Do not let a
            // partial multi-display start overwrite "Recovering…" with "Active".
            throw CaptureRequestBrokerError.cooldown(untilMonotonicTime: deadline)
        case .noDisplay:
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

    func stopCapture() async {
        isRunning = false
        reconcileTask?.cancel()
        reconcileTask = nil
        cancelCooldownRestart()
        let snapshot = Array(managed.values)
        managed.removeAll()
        let previousLoops = snapshot.map { $0.manager.beginStoppingCapture() }
        for previousLoop in previousLoops {
            await previousLoop?.value
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

    private func scheduleReconcile() {
        guard isRunning else { return }
        reconcileTask?.cancel()
        reconcileTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.reconcileDisplays(startNewManagers: true)
            } catch {
                if self.isRunning, !(error is CancellationError),
                   case CaptureError.permissionDenied = error {
                    // A revocation found during a system-event reconcile must
                    // reach the app's restart/permission flow, not vanish.
                    self.delegate?.captureCoordinatorDidStopUnexpectedly(self)
                }
            }
            self.reconcileTask = nil
        }
    }

    private func reconcileDisplays(startNewManagers: Bool) async throws {
        // If permission has genuinely been revoked, surface that immediately
        // instead of letting the request be classified as a cooldown deferral
        // (or touching ScreenCaptureKit at all).
        guard ScreenCaptureManager.hasScreenRecordingPermission() else {
            throw CaptureError.permissionDenied
        }
        let content: SCShareableContent
        do {
            // Brokered so reconcile and restart respect the shared circuit:
            // while it is cooling down after a false TCC denial, no code path
            // may touch ScreenCaptureKit and risk another native prompt.
            content = try await captureRequestBroker.perform(owner: reconcileRequestOwner) {
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            }
        } catch {
            // A genuine revocation must reach the app's permission flow even
            // when a circuit from an earlier false-denial episode is open.
            if CaptureFailureRecovery.isPermissionDenial(error),
               !ScreenCaptureManager.hasScreenRecordingPermission() {
                throw CaptureError.permissionDenied
            }
            if !(error is CancellationError),
               let deadline = captureRequestBroker.openCircuitMonotonicDeadline {
                scheduleCooldownRestart()
                throw CaptureRequestBrokerError.cooldown(untilMonotonicTime: deadline)
            }
            throw error
        }
        try Task.checkCancellation()

        var desired: [UUID: DisplayInfo] = [:]
        for display in content.displays {
            let info = DisplayIdentity.info(for: display)
            desired[info.id] = info
        }

        // Remove managers for displays that are no longer connected.
        let removedIDs = managed.keys.filter { desired[$0] == nil }
        let removedEntries = removedIDs.compactMap { managed.removeValue(forKey: $0) }
        let previousLoops = removedEntries.map { $0.manager.beginStoppingCapture() }
        for (entry, previousLoop) in zip(removedEntries, previousLoops) {
            await previousLoop?.value
            captureLogger.info("Capture stopped for removed display: \(entry.info.name, privacy: .public)")
            DiagnosticsLog.shared.log("Capture", "Capture stopped for removed display: \(entry.info.name)")
        }

        // Start managers for newly seen displays.
        if startNewManagers {
            for (id, info) in desired where managed[id] == nil {
                guard let physicalDisplayID = info.displayID else { continue }
                let manager = ScreenCaptureManager(
                    targetDisplayID: physicalDisplayID,
                    captureRequestBroker: captureRequestBroker
                )
                manager.delegate = self
                manager.updateCaptureInterval(captureInterval)
                manager.updateCaptureScale(captureScale)
                managed[id] = ManagedDisplay(info: info, manager: manager)
                do {
                    try await manager.startCapture()
                    captureLogger.info("Capture started for display: \(info.name, privacy: .public)")
                    DiagnosticsLog.shared.log("Capture", "Capture started for display: \(info.name)")
                } catch {
                    managed.removeValue(forKey: id)
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
                }
            }
        }

        delegate?.captureCoordinatorDidUpdateDisplays(self)
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
        guard cooldownRestartDeadline != deadline else { return }

        cooldownRestartTask?.cancel()
        cooldownRestartDeadline = deadline
        cooldownRestartGeneration += 1
        let generation = cooldownRestartGeneration
        let delay = remaining + 1
        DiagnosticsLog.shared.log(
            "Capture",
            "Capture start deferred; retrying in \(Int(delay)) seconds when the shared ScreenCaptureKit circuit cooldown ends"
        )
        cooldownRestartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            // Keep the task handle registered until this task finishes so
            // stopCapture() can still cancel it while the reconcile below is
            // in flight. Only clear state this generation still owns: the
            // reconcile may reopen the circuit and schedule a replacement.
            defer {
                if self.cooldownRestartGeneration == generation {
                    self.cooldownRestartTask = nil
                    self.cooldownRestartDeadline = nil
                }
            }
            guard !Task.isCancelled, self.isRunning else { return }
            // Allow a reopen during this reconcile to schedule the next
            // restart even if the broker lands on an identical deadline.
            self.cooldownRestartDeadline = nil
            do {
                try await self.reconcileDisplays(startNewManagers: true)
                guard self.isRunning, !Task.isCancelled else { return }
                if self.isCapturing, self.captureRequestBroker.isCircuitClosed {
                    // The broker publishes .normal when its half-open probe
                    // succeeds, which happens before any display is capturing,
                    // so the app skips the "Active" status update. Re-publish
                    // now that capture is actually running again — but only if
                    // no later display start reopened the circuit.
                    self.delegate?.captureCoordinator(self, didChangeRecoveryState: .normal)
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
                }
                // Cooldown failures already rescheduled another restart from
                // inside reconcileDisplays; other errors keep the existing
                // reconcile-on-system-event behaviour.
            }
        }
    }

    private func cancelCooldownRestart() {
        cooldownRestartTask?.cancel()
        cooldownRestartTask = nil
        cooldownRestartDeadline = nil
        // Invalidate any restart task that is past its cancellation checks so
        // its deferred cleanup cannot clear state from a later schedule.
        cooldownRestartGeneration += 1
    }

    // MARK: - ScreenCaptureDelegate

    func captureManager(_ manager: ScreenCaptureManager, didCaptureFrame image: CGImage, at timestamp: Date) {
        guard let entry = managed.values.first(where: { $0.manager === manager }) else { return }
        delegate?.captureCoordinator(self, didCaptureFrame: image, at: timestamp, from: entry.info)
    }

    func captureManagerDidStop(_ manager: ScreenCaptureManager) {
        // A single display dropped. If we're supposed to be running, ask the
        // delegate to treat this as an unexpected stop after removing the
        // stopped manager so the restart flow can create a fresh one.
        guard isRunning else { return }
        guard let stopped = managed.first(where: { $0.value.manager === manager }) else { return }
        managed.removeValue(forKey: stopped.key)
        delegate?.captureCoordinatorDidUpdateDisplays(self)
        delegate?.captureCoordinatorDidStopUnexpectedly(self)
    }
}
