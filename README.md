# JustNow

A native macOS menu bar app that continuously captures screenshots and lets you scroll back through the last 5-10 minutes of screen history via a hotkey-triggered fullscreen overlay.

## Features

- **Continuous capture**: Captures screenshots every 0.5 to 5 seconds
- **Perceptual hashing**: Skips near-identical frames to save memory (30-50% savings)
- **Exponential decay**: Recent frames kept at full density, older frames thinned out
- **Recent detail**: Browse the newest 1, 2, or 5 minutes using every stored frame before older history is collapsed
- **Battery conscious**: Can reduce quality/background work on battery without changing your chosen cadence
- **Fullscreen overlay**: Press ⌘⌥J to view timeline, scroll/drag to navigate
- **Menu bar only**: Runs silently with no dock icon

## Requirements

- macOS 15+
- Screen Recording permission

## Usage

1. Launch JustNow - it appears in the menu bar
2. Grant Screen Recording permission when prompted
3. Let it run to build up history
4. Press **⌘⌥J** to open the timeline overlay
5. Scroll horizontally or drag to navigate through time
6. Press **Escape** to dismiss

## Settings

Access via menu bar icon → Settings:

- **Capture interval**: 0.5s to 5s (default 0.5s)
- **Newest timeline detail**: 1, 2, or 5 minutes at full capture detail
- **Max frames**: 100 to 1200 (default 600, ~10 min at 1fps)
- **Battery mode**: Optional cadence preservation when unplugged

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
xcodebuild -scheme JustNow -configuration Release -derivedDataPath build
```

## Releases

Latest release is now:

- `v0.1.1` (download from GitHub Releases)

Release artefacts are built and notarised locally, then uploaded to GitHub Releases from the maintainer machine rather than from GitHub Actions.

## Licence

For distribution and maintainer release packaging details, see:

- `Docs/release-and-distribution.md`

Local distribution builds can now also be notarised with `Scripts/local-release-build.sh --notarize`, and GitHub release uploads can be done with `Scripts/local-release-publish.sh`; see the release doc for the full commands and required credentials.

MIT
