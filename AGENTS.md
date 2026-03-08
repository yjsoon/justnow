# AGENTS.md

## Overview

JustNow is a macOS menu bar app that captures screenshots and lets you scroll back through recent screen history in a fullscreen overlay.

- Target: macOS 26+, Swift 6.2, SwiftUI
- Bundle ID: `sg.tk.JustNow`
- Storage: `~/Library/Application Support/JustNow/`
- Hotkey: configurable, default `⌘⌥R`

## Release Stage

This app is pre-release. Prefer forward progress over backwards compatibility unless a task explicitly calls for migration support.

## Build And Run

```bash
xcodebuild -scheme JustNow -configuration Release -derivedDataPath build
```

After every successful build, always install and launch from `/Applications/` before reporting completion. Screen Recording permission is tied to the app location.

```bash
pkill -x JustNow 2>/dev/null || true
if [ -e /Applications/JustNow.app ]; then
  trash /Applications/JustNow.app
fi
cp -R build/Build/Products/Release/JustNow.app /Applications/
open /Applications/JustNow.app
```

If `open` fails in CLI contexts, use `xcodebuildmcp macos launch --app-path "/Applications/JustNow.app"`.

## Key Files

- `JustNow/AppDelegate.swift`: app lifecycle, menu bar, hotkey, capture policy
- `JustNow/Capture/FrameBuffer.swift`: frame dedupe, retention handoff, OCR queueing
- `JustNow/UI/OverlayWindowController.swift`: overlay window and keyboard handling
- `JustNow/Storage/FrameStore.swift`: manifest and image persistence
- `JustNow/Storage/RetentionManager.swift`: time-based pruning

## Notes

- Use `ScreenCaptureKit`; `CGWindowListCreateImage` is deprecated.
- Pruning is paused while the overlay is open.
- Frames persist across restarts via the on-disk manifest.
