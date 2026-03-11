//
//  LaunchAtLoginManager.swift
//  JustNow
//

import ServiceManagement

enum LaunchAtLoginError: LocalizedError {
    case serviceUnavailable

    var errorDescription: String? {
        "Launch on startup is not available in this build."
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
        switch service.status {
        case .enabled, .notRegistered, .requiresApproval:
            true
        case .notFound:
            false
        @unknown default:
            false
        }
    }

    func setEnabled(_ isEnabled: Bool) throws -> ChangeResult {
        if isEnabled {
            if service.status != .enabled {
                try service.register()
            }

            return service.status == .requiresApproval ? .requiresApproval : .updated
        }

        switch service.status {
        case .enabled, .requiresApproval:
            try service.unregister()
            return .updated
        case .notRegistered:
            return .updated
        case .notFound:
            throw LaunchAtLoginError.serviceUnavailable
        @unknown default:
            throw LaunchAtLoginError.serviceUnavailable
        }
    }
}
