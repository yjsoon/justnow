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

If you have just switched this Mac from an older dev-signed build to a Developer ID / notarised build and Screen Recording already appears enabled but JustNow still cannot capture, remove the `JustNow` entry from **System Settings → Privacy & Security → Screen Recording** once, then relaunch and grant access again. Later notarised updates signed with the same identity should keep working normally.

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

For routine local reinstalls, use:

```bash
./Scripts/local-install-app.sh
```

That helper keeps the app at `/Applications/JustNow.app` and prefers a stable Developer ID signature when available, which helps macOS retain the existing Screen Recording permission record across reinstalls.

If you only need to build without installing, open `JustNow.xcodeproj` in Xcode and build (⌘B), or:

```bash
xcodebuild -scheme JustNow -configuration Release -derivedDataPath build
```

## Testing

Run the macOS unit tests with:

```bash
xcodebuild test -project JustNow.xcodeproj -scheme JustNow -destination 'platform=macOS'
```

## Releases

Latest release is now:

- `v0.1.1` (download from GitHub Releases)

Release artefacts are built and notarised locally, then uploaded to GitHub Releases from the maintainer machine rather than from GitHub Actions.

## Public Site

This repo now also contains a static public site under `site/`.

- `site/index.html`: product landing page
- `site/releases/`: public release notes
- `site/appcast.xml`: Sparkle appcast served from the public site root

The public site is designed to work alongside GitHub Releases:

- signed `.zip` and `.dmg` artefacts stay on GitHub Releases
- the public app page, release notes, and Sparkle appcast are published from `site/`
- the site assumes a root-mounted custom domain, so root-absolute links are intentional
- `wrangler.jsonc` is configured for a Cloudflare Pages project named `justnow-site`

Repository builds now include Sparkle-based in-app update UI. Public Sparkle updates become fully live once a Sparkle-enabled release archive has been published and added to the appcast.

## Licence

For distribution and maintainer release packaging details, see:

- `Docs/release-and-distribution.md`
- `Docs/site-and-updates.md`
- `Docs/cloudflare-pages.md`

Local distribution builds can now also be notarised with `Scripts/local-release-build.sh --notarize`, and `Scripts/local-release-publish.sh` can publish GitHub Releases, refresh `site/releases.json`, regenerate release notes, rebuild `site/appcast.xml`, and deploy `site/` to Cloudflare Pages for stable releases; see the release doc for the full commands and required credentials.

MIT
