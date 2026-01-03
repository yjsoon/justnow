# JustNow

A native macOS menu bar app that continuously captures screenshots and lets you scroll back through the last 5-10 minutes of screen history via a hotkey-triggered fullscreen overlay.

## Features

- **Continuous capture**: Captures screenshots every 1-2 seconds (configurable)
- **Perceptual hashing**: Skips near-identical frames to save memory (30-50% savings)
- **Exponential decay**: Recent frames kept at full density, older frames thinned out
- **Battery conscious**: Reduces capture rate when on battery power
- **Fullscreen overlay**: Press ⌘⌥R to view timeline, scroll/drag to navigate
- **Menu bar only**: Runs silently with no dock icon

## Requirements

- macOS 13+ (Ventura)
- Screen Recording permission

## Usage

1. Launch JustNow - it appears in the menu bar
2. Grant Screen Recording permission when prompted
3. Let it run to build up history
4. Press **⌘⌥R** to open the timeline overlay
5. Scroll horizontally or drag to navigate through time
6. Press **Escape** to dismiss

## Settings

Access via menu bar icon → Settings:

- **Capture interval**: 0.5s to 5s (default 1s)
- **Max frames**: 100 to 1200 (default 600, ~10 min at 1fps)
- **Battery mode**: Reduce capture rate when unplugged

## Architecture

```
ScreenCaptureKit → Perceptual Hash Filter → Ring Buffer (RAM)
                                                    ↓
                                          Retention Manager
                                          (exponential decay)
```

## Building

Open `JustNow.xcodeproj` in Xcode and build (⌘B), or:

```bash
xcodebuild -scheme JustNow -project JustNow.xcodeproj build
```

## Licence

MIT
