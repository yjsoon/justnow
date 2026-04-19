// Adapted from https://github.com/zats/permiso. See ATTRIBUTION.md in this directory.

import AppKit
import Foundation

struct PermisoHostApp {
    let displayName: String
    let bundleURL: URL
    let icon: NSImage

    init(displayName: String, bundleURL: URL, icon: NSImage) {
        self.displayName = displayName
        self.bundleURL = bundleURL
        self.icon = icon
    }

    static func current(bundle: Bundle = .main) -> PermisoHostApp {
        // JustNow ships CFBundleDisplayName as an empty string deliberately so macOS
        // falls back to CFBundleName; treat blanks as missing instead of taking them.
        func nonEmpty(_ key: String) -> String? {
            guard let value = bundle.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else {
                return nil
            }
            return value
        }
        let displayName = nonEmpty("CFBundleDisplayName")
            ?? nonEmpty(kCFBundleNameKey as String)
            ?? bundle.bundleURL.deletingPathExtension().lastPathComponent
        let icon = NSWorkspace.shared.icon(forFile: bundle.bundleURL.path)
        icon.size = NSSize(width: 48, height: 48)
        return PermisoHostApp(displayName: displayName, bundleURL: bundle.bundleURL, icon: icon)
    }
}
