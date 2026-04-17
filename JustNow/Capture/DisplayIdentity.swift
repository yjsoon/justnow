//
//  DisplayIdentity.swift
//  JustNow
//

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Stable identifier + friendly name for a physical display.
///
/// `id` is derived from `CGDisplayCreateUUIDFromDisplayID` so it survives
/// unplug/replug during the retention window. `displayID` is the per-session
/// `CGDirectDisplayID` used to talk to CoreGraphics and match `NSScreen`.
struct DisplayInfo: Sendable, Equatable, Hashable {
    let id: UUID
    /// CoreGraphics display ID for the physical display, or nil when this
    /// DisplayInfo represents a historical display that isn't currently
    /// connected.
    let displayID: CGDirectDisplayID?
    let name: String

    var isConnected: Bool { displayID != nil }
}

enum DisplayIdentity {
    static func info(for scDisplay: SCDisplay) -> DisplayInfo {
        info(for: scDisplay.displayID)
    }

    static func info(for displayID: CGDirectDisplayID) -> DisplayInfo {
        DisplayInfo(
            id: stableUUID(for: displayID) ?? fallbackUUID(for: displayID),
            displayID: displayID,
            name: friendlyName(for: displayID)
        )
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { Self.displayID(for: $0) == displayID }
    }

    /// Returns the screen currently under the mouse, falling back to the main screen.
    static func screenContainingMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
    }

    private static func stableUUID(for displayID: CGDirectDisplayID) -> UUID? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        guard let string = CFUUIDCreateString(nil, cfUUID) as String? else { return nil }
        return UUID(uuidString: string)
    }

    /// Deterministic fallback keyed off the CGDirectDisplayID, used only when
    /// CoreGraphics refuses to provide a stable UUID (very rare).
    private static func fallbackUUID(for displayID: CGDirectDisplayID) -> UUID {
        var bytes: [UInt8] = [
            0x4A, 0x75, 0x73, 0x74, 0x4E, 0x6F, 0x77, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
        ]
        let big = displayID.bigEndian
        withUnsafeBytes(of: big) { buf in
            for index in 0..<4 {
                bytes[12 + index] = buf[index]
            }
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func friendlyName(for displayID: CGDirectDisplayID) -> String {
        if let screen = screen(for: displayID) {
            let name = screen.localizedName
            if !name.isEmpty { return name }
        }
        if CGDisplayIsBuiltin(displayID) != 0 {
            return "Built-in Display"
        }
        return "Display \(displayID)"
    }
}
