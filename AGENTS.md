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
./Scripts/local-install-app.sh
```

Use the helper above for routine local reinstalls. It keeps the app at `/Applications/JustNow.app` and prefers the same Developer ID signing identity, which avoids Screen Recording permission churn when this machine has the local release credentials configured.

If you only need a build artefact without installing it, you can still run:

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

This repo no longer uses GitHub Actions for release artefacts or public-site deployment. Archived workflows live under `.github/archived-workflows/`.

Local release credentials live in `.env.release.local` (gitignored). The local release scripts auto-load it if present, so future agents should check there first for `APPLE_SIGNING_IDENTITY`, `APPLE_TEAM_ID`, `APPLE_API_KEY_PATH`, `APPLE_API_KEY_ID`, and `APPLE_API_KEY_ISSUER_ID`.

After every successful build, always install and launch from `/Applications/` before reporting completion. Screen Recording permission is tied to the app location.

Prefer `./Scripts/local-install-app.sh` over manually copying a raw Xcode build whenever you are reinstalling the app locally. The helper refuses to replace an existing Developer ID-signed install with a differently signed build unless you explicitly reconfigure the signing inputs.

If you switch a machine from older dev-signed/Xcode builds to Developer ID or notarised builds, macOS may keep a stale Screen Recording entry that still appears enabled. If capture fails in that state, remove the `JustNow` entry from **System Settings → Privacy & Security → Screen Recording** once and relaunch so TCC can recreate it for the new signing identity.

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
- `Docs/site-and-updates.md`
- `Docs/cloudflare-pages.md`

## Key Files

- `JustNow/AppDelegate.swift`: app lifecycle, menu bar, hotkey, capture policy
- `JustNow/Capture/FrameBuffer.swift`: frame dedupe, retention handoff, OCR queueing
- `JustNow/UI/OverlayWindowController.swift`: overlay window and keyboard handling
- `JustNow/Storage/FrameStore.swift`: manifest and image persistence
- `JustNow/Storage/RetentionManager.swift`: time-based pruning
- `site/index.html`: public product page
- `site/releases.json`: source-of-truth public release metadata
- `site/appcast.xml`: Sparkle appcast published at the site root
- `wrangler.jsonc`: Cloudflare Pages project configuration for the public site
- `Scripts/deploy-public-site.sh`: Cloudflare Pages deployment helper for the public site

## Notes

- Use `ScreenCaptureKit`; `CGWindowListCreateImage` is deprecated.
- Pruning is paused while the overlay is open.
- Frames persist across restarts via the on-disk manifest.
- Keep GitHub Releases as the canonical home for signed app artefacts; the public site under `site/` should link to those assets rather than duplicating release binaries.
- The public site is intended for a root-mounted custom domain; root-absolute paths in `site/` are intentional unless deployment assumptions change.
- Sparkle is integrated in-app; stable release publishing should refresh `site/releases.json`, regenerate `site/releases/`, and rebuild `site/appcast.xml` from the uploaded archive.
- Stable release publishing should also deploy `site/` to Cloudflare Pages unless `--skip-site-deploy` is explicitly requested.
- Cloudflare Pages is the intended host for `justnow.tk.sg`; use `wrangler.jsonc` and `Docs/cloudflare-pages.md` as the source of truth for site deployment.
- Keep menu bar recording controls visually in sync: when pause/resume state changes, update both the menu item and the status item icon.
- In Settings, prefer native macOS patterns when aiming for system look and feel; use `Form` semantics and `LabeledContent` for label/control rows where appropriate.
- Settings rows should usually control real persisted behaviour rather than restating a fixed implementation detail.
- Product-facing settings copy should describe user outcomes rather than internal engine details such as retention compaction mechanics.
- Keep click-outside overlay dismissal; if keyboard dismissal becomes configurable, preserve `Escape` as the simple default.
- In the timeline UI, keep the recent-detail boundary and label priority aligned with the configured recent window rather than a hard-coded cutoff.
- If UI copy mentions a nominal capture interval, sanity-check it against adaptive throttling and deduplicated browsing so the user-facing wording still matches observed behaviour.
- Avoid stacking a custom permission alert on top of a macOS TCC prompt during first-launch flows; if the system dialog is already doing the ask, defer app guidance until after the user responds.
- When a SwiftUI view is exposed through both a `Settings` scene and an AppKit-hosted window, centralise construction and shared dependencies so both entry points stay in sync.
