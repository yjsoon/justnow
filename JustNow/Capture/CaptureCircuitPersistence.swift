import Foundation

struct PersistedCaptureCircuit: Equatable {
    var openedAt: Date
    var cooldownSeconds: TimeInterval
    var escalationLevel: Int
    var recoveredAt: Date?
}

protocol CaptureCircuitPersisting: AnyObject {
    func load() -> PersistedCaptureCircuit?
    func save(_ snapshot: PersistedCaptureCircuit)
    func clear()
}

enum CaptureCircuitStoreKey {
    static let openedAt = "captureCircuitOpenedAt"
    static let cooldownSeconds = "captureCircuitCooldownSeconds"
    static let escalationLevel = "captureCircuitEscalationLevel"
    static let recoveredAt = "captureCircuitRecoveredAt"
}

final class UserDefaultsCaptureCircuitStore: CaptureCircuitPersisting {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> PersistedCaptureCircuit? {
        guard defaults.object(forKey: CaptureCircuitStoreKey.openedAt) != nil else {
            return nil
        }
        let openedAt = Date(
            timeIntervalSince1970: defaults.double(forKey: CaptureCircuitStoreKey.openedAt)
        )
        return PersistedCaptureCircuit(
            openedAt: openedAt,
            cooldownSeconds: defaults.double(forKey: CaptureCircuitStoreKey.cooldownSeconds),
            escalationLevel: defaults.integer(forKey: CaptureCircuitStoreKey.escalationLevel),
            recoveredAt: defaults.object(forKey: CaptureCircuitStoreKey.recoveredAt).map { _ in
                Date(timeIntervalSince1970: defaults.double(forKey: CaptureCircuitStoreKey.recoveredAt))
            }
        )
    }

    func save(_ snapshot: PersistedCaptureCircuit) {
        defaults.set(snapshot.openedAt.timeIntervalSince1970, forKey: CaptureCircuitStoreKey.openedAt)
        defaults.set(snapshot.cooldownSeconds, forKey: CaptureCircuitStoreKey.cooldownSeconds)
        defaults.set(snapshot.escalationLevel, forKey: CaptureCircuitStoreKey.escalationLevel)
        if let recoveredAt = snapshot.recoveredAt {
            defaults.set(recoveredAt.timeIntervalSince1970, forKey: CaptureCircuitStoreKey.recoveredAt)
        } else {
            defaults.removeObject(forKey: CaptureCircuitStoreKey.recoveredAt)
        }
    }

    func clear() {
        defaults.removeObject(forKey: CaptureCircuitStoreKey.openedAt)
        defaults.removeObject(forKey: CaptureCircuitStoreKey.cooldownSeconds)
        defaults.removeObject(forKey: CaptureCircuitStoreKey.escalationLevel)
        defaults.removeObject(forKey: CaptureCircuitStoreKey.recoveredAt)
    }
}

enum CapturePermissionGate: Equatable {
    case allowed
    case coolingDown
    case denied

    static func resolve(hasPermission: Bool, circuitIsOpen: Bool) -> CapturePermissionGate {
        if hasPermission {
            return .allowed
        }
        if circuitIsOpen {
            return .coolingDown
        }
        return .denied
    }
}

enum CapturePermissionPreflight {
    static func waitForGrant(
        hasPermission: () -> Bool,
        attempts: Int = 4,
        interval: Duration = .milliseconds(400),
        sleep: (Duration) async -> Void
    ) async -> Bool {
        if hasPermission() {
            return true
        }
        for _ in 0..<attempts {
            await sleep(interval)
            if hasPermission() {
                return true
            }
        }
        return false
    }
}
