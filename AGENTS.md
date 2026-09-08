# AGENTS.md

## Project

JustNow is a released macOS 15+ menu bar app for rewinding recent screen history, built with Swift, SwiftUI, and AppKit. Bundle ID: `sg.tk.JustNow`; default overlay hotkey: `⌘⌥J`.

Prefer simple, forward-moving implementations while preserving users' settings and stored history. Do not add speculative compatibility layers; raise intentional breaking changes or migration removal for approval.

## Autonomy and authorization

- Within the requested task, investigate, make safe local fixes, run relevant checks, and fix/rerun failures caused by the change without asking at each step. Preserve unrelated work.
- On a Mac, useful day-to-day app fixes and improvements should normally end with a verified install and launch from `/Applications/JustNow.app`. Announce the restart; a graceful interruption of the running app is authorized. Ask before force-killing if graceful shutdown fails. Follow [local development](Docs/local-development.md) before replacement.
- Routine local signing with the existing matching Developer ID identity is authorized. If the identity is missing or would change, ask rather than silently falling back. Keep the stable app path and signing identity to minimize TCC permission churn.
- Cloud environments, documentation/site-only tasks, and intermediate builds do not require app installation. Do not interrupt the app merely because a build succeeded.
- Official distribution preparation, notarisation, and publication require explicit authorization for those actions; local-install permission does not grant it. A request to publish a stable release includes updating and deploying its website version metadata, release notes, and appcast unless the user excludes them.
- Unrelated website changes/deployment, account/project/domain provisioning, and signing-identity changes need their own authorization. Do not infer permission to push, merge, create/move tags, or overwrite existing release assets; confirm that these are within the requested scope.

## Privacy and data

- Screen history and OCR data live under `~/Library/Application Support/JustNow/`. Treat images, recognised text, databases and WAL/SHM/journal sidecars, recovery copies, exports, logs, and credentials as sensitive. Do not expose them in commits, uploads, screenshots, or tool output.
- Use synthetic images and injected temporary storage for tests. Never delete, migrate, or reset live user data or TCC to make a check pass; obtain specific authorization for live-data operations.
- Preserve owner-only storage, backup exclusion, no-content diagnostics, and first-launch permission behavior. TCC recovery is conditional and user-assisted, not routine cleanup.
- Keep credentials out of git and logs. Credential-file presence is not permission to execute/source its contents or use signing services outside the authorized task.

## Verification

- Scale checks to the change: accuracy/links for docs; focused tests and a build for localized app work; broader regression coverage for shared capture, storage, privacy, or lifecycle changes.
- For visual changes, inspect rendered affected states, including changed non-default states; compilation alone is not visual verification. Use synthetic or non-sensitive content.
- Verify actual launch and the affected behavior after a local reinstall. Hosted unit tests are not an installed-app smoke test.
- If the environment or authorization blocks a required check, complete independent safe checks and report the remaining gap. Do not claim unexecuted tests or app behavior passed.

## Task references

Read the reference relevant to the task, not every document or the whole repository:

- App behavior and UI: [JustNow/AGENTS.md](JustNow/AGENTS.md).
- Build, test, install, and TCC troubleshooting: [local development](Docs/local-development.md).
- Official artifacts and publication: [release and distribution](Docs/release-and-distribution.md).
- Static site generation and preview: [site and updates](Docs/site-and-updates.md).
- Website deployment and target checks: [Cloudflare Pages](Docs/cloudflare-pages.md).

## Ownership entry points

- `JustNow/AppDelegate.swift` and `JustNow/Capture/`: lifecycle, capture coordination, frame buffering, retention handoff, and OCR queueing.
- `JustNow/Storage/FrameStore.swift`, `FrameDatabase.swift`, `HybridFrameRepository.swift`, and `TextCache.swift`: durable images/SQLite, memory-resident recent history, and OCR/search data.
- `JustNow/UI/`: overlay presentation, timeline/search, drag actions, Settings, and menu bar controls.
- `.github/workflows/unit-tests.yml`: macOS test command. Release/site workflows are archived under `.github/archived-workflows/`; they are not active publishing paths.
