# App Guidance

Follow the root guidance for privacy, authorization, and verification; see [local development](../Docs/local-development.md) for build/test/install procedures.

## Capture and storage

- Use `ScreenCaptureKit`, not deprecated `CGWindowListCreateImage`.
- Keep pruning paused while the overlay is open so browsing does not lose its selected frame.
- Durable images and metadata are owned by `FrameStore`/`FrameDatabase` (SQLite); `TextCache` stores OCR/search data. `manifest.json` is a legacy migration input, not the current persistence model.
- `HybridFrameRepository` keeps recent detail in memory with durable recovery points. Normal quit preserves the latest frame per display; other memory-only detail is temporary. Do not promise that all recent frames survive restart.
- Preserve existing settings/history migrations and private-storage protections. Test persistence, recovery, retention, and deletion changes against injected temporary stores, never live history.
- Avoid stacking custom permission guidance over the native TCC prompt. Wait for its resolution; preserve capture recovery behavior instead of treating every capture failure as revoked permission.

## UI outcomes

- Keep pause/resume menu text and status item icon in sync (`StatusItemController`).
- Prefer native macOS Settings patterns, using `Form` and `LabeledContent` where appropriate. Rows should control persisted behavior and describe user outcomes, not internal compaction mechanics.
- Centralise shared Settings construction/dependencies across the SwiftUI `Settings` scene and AppKit-hosted window (`SettingsContext` and `SettingsWindowCoordinator`).
- Preserve click-outside overlay dismissal and Escape as the simple default keyboard dismissal.
- Keep drag actions discoverable with lightweight in-frame hints. Honor the configured text-grab/screenshot default and Command for the alternate action, rather than assuming plain drag always grabs text.
- Keep timeline recent-detail boundaries and label priority aligned with the configured recent window, not a hard-coded cutoff.
- Check capture-interval copy against adaptive throttling and deduplicated browsing; a nominal interval is not a guarantee of distinct stored frames.

Use the relevant classes in `JustNowTests/` for focused verification. Shared storage/capture/lifecycle changes need broader coverage; inspect representative rendered states for appearance changes, including alternate drag modes or Settings entry points when affected.
