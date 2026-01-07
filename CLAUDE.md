# JustNow

macOS menu bar app that continuously captures screenshots and lets you scroll back through screen history via a hotkey-triggered fullscreen overlay.

## Quick Reference

- **Bundle ID:** sg.tk.JustNow
- **Target:** macOS 13+, Swift, SwiftUI
- **Hotkey:** Customisable (default ⌘⌥R), Escape to dismiss
- **Storage:** `~/Library/Application Support/JustNow/`
- **Dependency:** [soffes/HotKey](https://github.com/soffes/HotKey) (SPM)

## Architecture

```
ScreenCaptureKit → Perceptual Hash Filter → FrameBuffer (RAM) → Disk (JPEG)
                   (skip unchanged frames)   (with thumbnails)   (manifest.json)
```

Key constraints:
- All data stays local, no network
- Battery-conscious: adaptive capture rate on battery
- Exponential decay retention (denser for recent frames)

## File Structure

```
JustNow/
├── JustNowApp.swift              # @main entry point
├── AppDelegate.swift             # Menu bar, hotkey, lifecycle
├── Capture/
│   ├── ScreenCaptureManager.swift
│   ├── FrameBuffer.swift
│   └── PerceptualHash.swift
├── Storage/
│   ├── FrameStore.swift          # Disk persistence
│   ├── FrameMetadata.swift
│   ├── RetentionManager.swift
│   └── ThumbnailGenerator.swift
├── UI/
│   ├── OverlayWindowController.swift
│   ├── OverlayView.swift
│   ├── SettingsView.swift
│   └── KeyboardShortcutRecorder.swift
└── Utilities/
    ├── PowerManager.swift
    └── ImageUtils.swift
```

## Build & Run

```bash
# Build release
xcodebuild -project JustNow.xcodeproj -scheme JustNow -configuration Release build

# Copy to Applications
cp -R ~/Library/Developer/Xcode/DerivedData/JustNow-*/Build/Products/Release/JustNow.app /Applications/
```

Or use XcodeBuildMCP: `build_macos()` then `build_run_macos()`

## Key Implementation Notes

1. **ScreenCaptureKit only** - CGWindowListCreateImage deprecated in macOS 15
2. **NSPanel with .screenSaver level** - overlay appears above fullscreen apps
3. **Perceptual hashing** - skips storing near-identical frames (30-50% savings)
4. **App Nap prevention** - uses `ProcessInfo.beginActivity()` during capture
5. **Sleep/wake handling** - restarts capture stream after wake
