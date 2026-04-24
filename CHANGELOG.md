# Changelog

All notable changes to JustNow will be documented in this file.

## [Unreleased]

## [1.2.0] - 2026-04-24

### Added
- Added multi-display capture and rewind support, including monitor selection in the overlay.
- Added clearer Screen Recording permission guidance during first launch and recovery.

### Changed
- Polished overlay monitor selection copy, alignment, and selected-state highlight.

### Fixed
- Fixed stopped display capture recovery so capture can restart cleanly after display changes.
- Fixed target-display matching so missing displays fail explicitly instead of capturing a different monitor under stale identity.

## [1.1.0] - 2026-04-18

### Added
- Added a setting to hide the JustNow menu bar icon when you prefer to rely on the shortcut or relaunching from Finder/Spotlight.
- Added a compact rewind-overlay toggle so the menu bar icon can be restored even while it is hidden.

### Changed
- Reopening the app from Finder or Spotlight now opens Settings when the menu bar icon is hidden, making recovery explicit.
- Refined the rewind timeline footer layout so capture details and text-grab feedback sit more cleanly.

## [1.0.0] - 2026-04-16

### Changed
- Refined overlay backdrop and timeline chrome for a polished rewind experience.
- Fixed overlay backdrop sync so it tracks the presented frame correctly.
- Fixed OCR indexing queue policy to prevent duplicate work.
- Refreshed homepage copy and feature coverage.

### Internal
- Major architecture refactor: extracted discrete controllers for capture start, stop, policy, events, and hot keys; separated screen recording permission state, capture lifecycle state, and status item controller.
- Extracted OCR indexing worker, black frame detector, and OCR frame queue into standalone modules.
- Split overlay view model, timeline helpers, keyboard action resolver, and view components for clearer boundaries.
- Centralised app storage defaults and capture restart scheduling.
- Streamlined text cache statements.
- Stabilised test suite for capture and refactor coverage.

## [0.3.0] - 2026-04-08

### Added
- Added indexed full-history search in the rewind overlay so you can find retained screen text without scrubbing frame by frame.
- Added in-frame search match highlighting to make matched words easier to spot once a result is open.
- Added clickable overlay controls for close, previous/next frame, and search.
- Added a configurable pause/resume shortcut and improved pause state visibility in the menu bar.

### Changed
- Smoothed search and scrolling transitions in the rewind overlay.
- Refined the overlay chrome and keyboard hint layout so mouse controls and shortcut hints stay aligned.

## [0.2.0] - 2026-03-23

### Added
- Added drag-to-grab text in rewind so you can draw over part of a frame and copy OCR text straight to the clipboard.
- Added rewind settings for a copied-text confirmation sound and an optional text-grab debug preview.

### Changed
- Improved OCR quality for text grabs by using higher-quality recognition and cleaning up clipboard text before it is copied.
- Refined the text-grab selection overlay and moved OCR feedback into the rewind footer.
- Simplified adaptive power settings.

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
