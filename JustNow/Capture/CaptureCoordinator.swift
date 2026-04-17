//
//  CaptureCoordinator.swift
//  JustNow
//

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

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
}

extension CaptureCoordinatorDelegate {
    func captureCoordinatorDidUpdateDisplays(_ coordinator: CaptureCoordinator) {}
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

    private var managed: [UUID: ManagedDisplay] = [:]
    private var captureInterval: TimeInterval = 1.0
    private var captureScale: Int = 2
    private var isRunning = false
    private var screenParamsObserver: NSObjectProtocol?
    private var reconcileTask: Task<Void, Never>?

    override init() {
        super.init()
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
        if managed.isEmpty {
            throw CaptureError.noDisplay
        }
    }

    func stopCapture() async {
        isRunning = false
        reconcileTask?.cancel()
        reconcileTask = nil
        let snapshot = Array(managed.values)
        managed.removeAll()
        for entry in snapshot {
            await entry.manager.stopCapture()
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
            try? await self.reconcileDisplays(startNewManagers: true)
            self.reconcileTask = nil
        }
    }

    private func reconcileDisplays(startNewManagers: Bool) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()

        var desired: [UUID: DisplayInfo] = [:]
        for display in content.displays {
            let info = DisplayIdentity.info(for: display)
            desired[info.id] = info
        }

        // Remove managers for displays that are no longer connected.
        let removedIDs = managed.keys.filter { desired[$0] == nil }
        for id in removedIDs {
            if let entry = managed.removeValue(forKey: id) {
                await entry.manager.stopCapture()
                print("Capture stopped for removed display: \(entry.info.name)")
            }
        }

        // Start managers for newly seen displays.
        if startNewManagers {
            for (id, info) in desired where managed[id] == nil {
                guard let physicalDisplayID = info.displayID else { continue }
                let manager = ScreenCaptureManager(targetDisplayID: physicalDisplayID)
                manager.delegate = self
                manager.updateCaptureInterval(captureInterval)
                manager.updateCaptureScale(captureScale)
                managed[id] = ManagedDisplay(info: info, manager: manager)
                do {
                    try await manager.startCapture()
                    print("Capture started for display: \(info.name)")
                } catch {
                    print("Failed to start capture for \(info.name): \(error)")
                    managed.removeValue(forKey: id)
                    if error is CaptureError, case CaptureError.permissionDenied = error {
                        throw error
                    }
                }
            }
        }

        delegate?.captureCoordinatorDidUpdateDisplays(self)
    }

    // MARK: - ScreenCaptureDelegate

    func captureManager(_ manager: ScreenCaptureManager, didCaptureFrame image: CGImage, at timestamp: Date) {
        guard let entry = managed.values.first(where: { $0.manager === manager }) else { return }
        delegate?.captureCoordinator(self, didCaptureFrame: image, at: timestamp, from: entry.info)
    }

    func captureManagerDidStop(_ manager: ScreenCaptureManager) {
        // A single display dropped. If we're supposed to be running, ask the
        // delegate to treat this as an unexpected stop and let the normal
        // restart flow re-enter reconcileDisplays.
        guard isRunning else { return }
        delegate?.captureCoordinatorDidStopUnexpectedly(self)
    }
}
