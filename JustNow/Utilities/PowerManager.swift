//
//  PowerManager.swift
//  JustNow
//

import IOKit.ps
import Foundation

class PowerManager {
    static func isOnBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let powerSource = info[kIOPSPowerSourceStateKey as String] as? String else {
                continue
            }
            return powerSource == kIOPSBatteryPowerValue as String
        }
        return false
    }

    static func batteryChargeFraction() -> Double? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let powerSource = info[kIOPSPowerSourceStateKey as String] as? String else {
                continue
            }

            guard powerSource == kIOPSBatteryPowerValue as String else {
                continue
            }

            if let current = info[kIOPSCurrentCapacityKey as String] as? Double,
               let max = info[kIOPSMaxCapacityKey as String] as? Double,
               max > 0 {
                return min(max(current / max, 0), 1)
            }

            if let current = info[kIOPSCurrentCapacityKey as String] as? Int,
               let max = info[kIOPSMaxCapacityKey as String] as? Int,
               max > 0 {
                return min(max(Double(current) / Double(max), 0), 1)
            }

            if let percent = info[kIOPSCurrentCapacityKey as String] as? Int {
                return min(max(Double(percent) / 100, 0), 1)
            }

            if let percent = info[kIOPSCurrentCapacityKey as String] as? Double {
                return min(max(percent / 100, 0), 1)
            }
        }

        return nil
    }
}

class AppNapPreventer {
    private var activityToken: NSObjectProtocol?

    func startActivity() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Screen capture active"
        )
    }

    func stopActivity() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }
}
