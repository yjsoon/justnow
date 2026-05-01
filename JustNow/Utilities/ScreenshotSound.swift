//
//  ScreenshotSound.swift
//  JustNow
//

import AppKit
import Foundation

/// Resolves and plays the "saved a screenshot" SFX.
///
/// Resolution order:
///   1. macOS system Screen Capture sound (`Screen Capture.aif`)
///   2. macOS system shutter sound (`Shutter.aif`)
///   3. Bundled CC0 fallback (`ShutterFallback.wav`)
///
/// We prefer the system files because they're already on the user's machine —
/// no redistribution, and on supported macOS versions the user hears the same
/// click they expect from `⇧⌘3`. The bundled fallback exists in case Apple
/// moves or removes those assets.
enum ScreenshotSound {
    private static let systemSoundCandidates = [
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Shutter.aif"
    ]

    static func play() {
        guard let url = resolvedURL(),
              let sound = NSSound(contentsOf: url, byReference: false)
        else { return }
        sound.stop()
        sound.play()
    }

    static func resolvedURL(fileManager: FileManager = .default, bundle: Bundle = .main) -> URL? {
        for path in systemSoundCandidates where fileManager.isReadableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return bundle.url(forResource: "ShutterFallback", withExtension: "wav")
    }
}
