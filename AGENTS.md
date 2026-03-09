# AGENTS.md

## Overview

JustNow is a macOS menu bar app that captures screenshots and lets you scroll back through recent screen history in a fullscreen overlay.

- Target: macOS 15+, Swift 6.2, SwiftUI
- Bundle ID: `sg.tk.JustNow`
- Storage: `~/Library/Application Support/JustNow/`
- Hotkey: configurable, default `⌘⌥J`

## Release Stage

This app is pre-release. Prefer forward progress over backwards compatibility unless a task explicitly calls for migration support.
Do not create or move tags or publish releases unless explicitly requested by the user.

## Build And Run

```bash
xcodebuild -scheme JustNow -configuration Release -derivedDataPath build
```

For local release packaging:

```bash
chmod +x Scripts/local-release-build.sh
./Scripts/local-release-build.sh [version]
```

To build distribution-ready artifacts (Developer ID signing) locally:

```bash
./Scripts/local-release-build.sh [version] --distribution --identity "Developer ID Application: Team Name (TEAMID)" --team TEAMID
```

To build a locally notarised and stapled DMG:

```bash
./Scripts/local-release-build.sh [version] \
  --distribution \
  --notarize \
  --identity "Developer ID Application: Team Name (TEAMID)" \
  --team TEAMID \
  --api-key /path/to/AuthKey_KEYID.p8 \
  --api-key-id KEYID \
  --api-issuer ISSUER-UUID
```

If the App Store Connect key is an Individual key, omit `--api-issuer`.

Artifacts are written to `dist/` and can be uploaded directly to GitHub Releases.

To build and upload a GitHub release from this machine:

```bash
./Scripts/local-release-publish.sh vX.Y.Z \
  --title "JustNow vX.Y.Z" \
  --identity "Developer ID Application: Team Name (TEAMID)" \
  --team TEAMID \
  --api-key /path/to/AuthKey_KEYID.p8 \
  --api-key-id KEYID \
  --api-issuer ISSUER-UUID
```

This repo no longer uses GitHub Actions to build release artefacts. The old workflow has been archived under `.github/archived-workflows/`.

Local release credentials live in `.env.release.local` (gitignored). The local release scripts auto-load it if present, so future agents should check there first for `APPLE_SIGNING_IDENTITY`, `APPLE_TEAM_ID`, `APPLE_API_KEY_PATH`, `APPLE_API_KEY_ID`, and `APPLE_API_KEY_ISSUER_ID`.

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

Release process and signing/deployment details are documented in:

- `Docs/release-and-distribution.md`

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
