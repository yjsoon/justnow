//
//  ScreenshotSaveLocation.swift
//  JustNow
//

import Foundation

/// Pure inputs to the screenshot save-location resolver.
///
/// All fields are simple values rather than live `UserDefaults` snapshots so
/// the resolver itself stays trivial to test (functional core).
struct ScreenshotSaveLocationInputs: Equatable {
    /// JustNow's own override path. Empty string = unset.
    var overridePath: String

    /// macOS' system screenshots `location` from `com.apple.screencapture`.
    /// May be `nil`, tilde-prefixed, or absolute.
    var systemLocationRaw: String?

    /// Resolved Desktop URL (the ultimate fallback). Injected so tests can
    /// avoid touching the real filesystem if they wish.
    var desktopURL: URL
}

enum ScreenshotSaveLocation {
    /// Resolve the directory that screenshots should be written to, in this
    /// order, falling through on validation failure:
    ///
    /// 1. `overridePath` (JustNow setting) — empty string skips this.
    /// 2. `systemLocationRaw` (macOS' screenshot `location` default).
    /// 3. `desktopURL` (`~/Desktop`).
    ///
    /// `directoryExists` is the validation hook: it returns `true` when the
    /// supplied URL points to an existing directory we can plausibly write
    /// into. Tests can supply an in-memory predicate; production passes a
    /// closure that defers to `FileManager`.
    static func resolve(
        inputs: ScreenshotSaveLocationInputs,
        directoryExists: (URL) -> Bool
    ) -> URL {
        if let candidate = candidateFromOverride(inputs.overridePath),
           directoryExists(candidate) {
            return candidate
        }

        if let candidate = candidateFromSystemLocation(inputs.systemLocationRaw),
           directoryExists(candidate) {
            return candidate
        }

        return inputs.desktopURL
    }

    /// Live convenience that wires the pure resolver up to the real
    /// `FileManager`, the running app's `UserDefaults`, and the system
    /// `com.apple.screencapture` domain.
    static func resolveLive(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> URL {
        let override = defaults.string(forKey: AppStorageKey.screenshotSaveLocationOverride) ?? ""
        let systemRaw = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        let desktop = (try? fileManager.url(
            for: .desktopDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop", isDirectory: true)

        let inputs = ScreenshotSaveLocationInputs(
            overridePath: override,
            systemLocationRaw: systemRaw,
            desktopURL: desktop
        )

        return resolve(inputs: inputs, directoryExists: { url in
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        })
    }

    // MARK: - Helpers

    private static func candidateFromOverride(_ path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: expandTilde(trimmed), isDirectory: true)
    }

    private static func candidateFromSystemLocation(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: expandTilde(raw), isDirectory: true)
    }

    private static func expandTilde(_ raw: String) -> String {
        (raw as NSString).expandingTildeInPath
    }
}
