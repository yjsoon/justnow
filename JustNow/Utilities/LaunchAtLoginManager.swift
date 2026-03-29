//
//  LaunchAtLoginManager.swift
//  JustNow
//

import os
import ServiceManagement

enum LaunchAtLoginError: LocalizedError {
    case serviceUnavailable
    case registrationFailed(underlying: any Error)

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            "Launch on startup is not available in this build."
        case .registrationFailed(let underlying):
            "Could not toggle launch on startup: \(underlying.localizedDescription). Try moving JustNow to /Applications, or restart your Mac."
        }
    }
}

@MainActor
final class LaunchAtLoginManager {
    enum ChangeResult {
        case updated
        case requiresApproval
    }

    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    var isEnabled: Bool {
        switch service.status {
        case .enabled, .requiresApproval:
            true
        case .notRegistered, .notFound:
            false
        @unknown default:
            false
        }
    }

    var canConfigure: Bool {
        // Always allow attempts — .notFound is common when the BTM database
        // hasn't catalogued the app yet (e.g. CLI installs).  Calling
        // register() often resolves the state, and if it truly can't work the
        // error is surfaced in the settings alert.
        true
    }

    private static let log = Logger(subsystem: "sg.tk.JustNow", category: "LaunchAtLogin")

    func setEnabled(_ isEnabled: Bool) throws -> ChangeResult {
        Self.log.info("setEnabled(\(isEnabled)), current status: \(String(describing: self.service.status))")

        if isEnabled {
            if service.status != .enabled {
                do {
                    try service.register()
                } catch {
                    Self.log.error("register() failed: \(error)")
                    throw LaunchAtLoginError.registrationFailed(underlying: error)
                }
            }

            Self.log.info("After register, status: \(String(describing: self.service.status))")
            return service.status == .requiresApproval ? .requiresApproval : .updated
        }

        switch service.status {
        case .enabled, .requiresApproval:
            try service.unregister()
            return .updated
        case .notRegistered, .notFound:
            return .updated
        @unknown default:
            throw LaunchAtLoginError.serviceUnavailable
        }
    }
}
