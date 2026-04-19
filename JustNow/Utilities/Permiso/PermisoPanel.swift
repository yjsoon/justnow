// Adapted from https://github.com/zats/permiso. See ATTRIBUTION.md in this directory.
// Kept local because upstream's Package.swift pins to macOS 26 while JustNow targets macOS 15.

import AppKit
import Foundation

enum PermisoPanel: String, CaseIterable {
    case accessibility = "Privacy_Accessibility"
    case screenRecording = "Privacy_ScreenCapture"

    var title: String {
        switch self {
        case .accessibility:
            "Accessibility"
        case .screenRecording:
            "Screen Recording"
        }
    }

    var settingsURL: URL {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(rawValue)") else {
            preconditionFailure("Invalid System Settings URL for \(rawValue)")
        }
        return url
    }
}
