# Changelog

All notable changes to JustNow will be documented in this file.

## [Unreleased]

### Added
- Added Sparkle-based in-app update support, including a new Settings software update section and a menu bar `Check for Updates…` action.
- Added an in-repo `site/` directory for the public app page, release notes, and the Sparkle appcast.
- Added a GitHub Pages deployment workflow for publishing the static site without moving app binary builds back into GitHub Actions.
- Added `site/releases.json` and site-generation scripts so public release notes can be generated from structured release metadata.
- Added Cloudflare Pages configuration and setup notes for hosting the public site at `justnow.tk.sg`.

### Changed
- Updated the local release tooling to re-sign Sparkle helper binaries for distribution builds and regenerate the public appcast for stable GitHub releases.

## [0.1] - 2026-03-08

### Added
- Initial release of JustNow.
- Added custom app and menu bar icon assets for clearer recording state feedback.
- Added reproducible icon source files under `Assets/IconSources`.
- Improved status bar icon rendering to use dedicated idle and recording images.
- Updated the default keyboard shortcut to `⌘⌥J` for opening the overlay.
