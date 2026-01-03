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
