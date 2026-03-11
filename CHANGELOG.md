# Changelog

All notable changes to JustNow will be documented in this file.

## [Unreleased]

## [0.1.3] - 2026-03-12

### Added
- Added recent timeline window controls so the overlay can focus on a shorter slice of recent capture history.
- Added an in-app Screen Recording help entry in the menu bar for reopening the recovery guidance when permission setup needs manual attention.

### Changed
- Improved Screen Recording permission recovery for machines switching from older dev-signed builds to Developer ID or notarised builds.
- Refined the launch-time permission flow so JustNow avoids stacking its own guidance on top of the macOS Screen Recording prompt.
- Cleaned up the Settings window title and local worktree build handling.

## [0.1.2] - 2026-03-10

### Added
- Added Sparkle-based in-app update support, including a new Settings software update section and a menu bar `Check for Updates…` action.
- Added an in-repo `site/` directory for the public app page, release notes, and the Sparkle appcast.
- Added a GitHub Pages deployment workflow for publishing the static site without moving app binary builds back into GitHub Actions.
- Added `site/releases.json` and site-generation scripts so public release notes can be generated from structured release metadata.
- Added Cloudflare Pages configuration and setup notes for hosting the public site at `justnow.tk.sg`.

### Changed
- Updated the local release tooling to re-sign Sparkle helper binaries for distribution builds and regenerate the public appcast for stable GitHub releases.
- Updated the local release tooling to deploy the refreshed public site to Cloudflare Pages as part of stable release publishing.

## [0.1] - 2026-03-08

### Added
- Initial release of JustNow.
- Added custom app and menu bar icon assets for clearer recording state feedback.
- Added reproducible icon source files under `Assets/IconSources`.
- Improved status bar icon rendering to use dedicated idle and recording images.
- Updated the default keyboard shortcut to `⌘⌥J` for opening the overlay.
