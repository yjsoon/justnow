# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

macOS menu bar app that continuously captures screenshots and lets you scroll back through screen history via a hotkey-triggered fullscreen overlay.

- **Bundle ID:** sg.tk.JustNow
- **Target:** macOS 26+, Swift 6.2, SwiftUI
- **Hotkey:** Customisable (default ⌘⌥R), Escape to dismiss
- **Storage:** `~/Library/Application Support/JustNow/` (JPEG + manifest.json)
- **Dependency:** [soffes/HotKey](https://github.com/soffes/HotKey) (SPM)

## Build Commands

```bash
# Build release
xcodebuild -scheme JustNow -configuration Release -derivedDataPath build

# Install and launch (required - app must run from /Applications for proper permissions)
pkill -x JustNow 2>/dev/null; cp -R build/Build/Products/Release/JustNow.app /Applications/ && open /Applications/JustNow.app
```

**Note:** Always install to `/Applications/` before testing. The app requires Screen Recording permission which is tied to the app location.

## Architecture

```
ScreenCaptureKit → FrameBuffer → FrameStore (disk)
     ↓                               ↓
 CVPixelBuffer           manifest.json + JPEG files
                                     ↓
                            RetentionManager
                         (time-based pruning)
```

**Data flow:**
1. `ScreenCaptureManager` captures frames via ScreenCaptureKit at configurable intervals
2. `FrameBuffer` receives CVPixelBuffer, converts to CGImage, saves via `FrameStore`
3. `FrameStore` persists full images + thumbnails as JPEG, tracks in manifest.json
4. `RetentionManager` prunes old frames based on time tiers (denser for recent)

**Retention tiers:**
- 0-10s: keep all frames
- 10-60s: ~2s intervals
- 1-5min: ~5s intervals
- 5min-24h: ~30s intervals (archive)

## Key Files

- `AppDelegate.swift` - Menu bar setup, hotkey registration, capture lifecycle, sleep/wake handling
- `FrameBuffer.swift` - Central frame management, coordinates capture→storage→pruning
- `OverlayWindowController.swift` - NSPanel overlay, keyboard/scroll event handling
- `RetentionManager.swift` - Time-based pruning logic with tier system
- `FrameStore.swift` - Actor for disk I/O, manifest management

## Implementation Notes

1. **ScreenCaptureKit only** - CGWindowListCreateImage deprecated in macOS 15
2. **Liquid Glass UI** - overlay uses `.glassEffect()` with `GlassEffectContainer`
3. **NSPanel at .statusBar+1 level** - overlay appears above most apps
4. **Pruning paused while overlay open** - prevents "Frame removed" errors
5. **@concurrent hash computation** - `PerceptualHash.compute()` runs on background thread
6. **App Nap prevention** - uses `ProcessInfo.beginActivity()` during capture
7. **Sleep/wake handling** - restarts capture stream after wake (2s delay)
8. **Frames persist across restarts** - loaded from disk on launch via manifest

## Apple Documentation Reference

For macOS 26 / Swift 6.2 features, refer to Xcode's bundled docs:
`/Applications/Xcode.app/Contents/PlugIns/IDEIntelligenceChat.framework/Versions/A/Resources/AdditionalDocumentation/`

Relevant files:
- `SwiftUI-Implementing-Liquid-Glass-Design.md` - `.glassEffect()`, `GlassEffectContainer`
- `AppKit-Implementing-Liquid-Glass-Design.md` - `NSGlassEffectView`
- `Swift-Concurrency-Updates.md` - `@concurrent`, approachable concurrency
- `Swift-InlineArray-Span.md` - `InlineArray`, `Span` for performance
