# JustNow

JustNow is a native macOS menu bar app that keeps a rolling record of your recent screen history, so you can jump back to something you just saw without breaking flow.

[Download the latest release](https://github.com/yjsoon/justnow/releases/latest)

## Highlights

- Opens a fullscreen rewind timeline from the menu bar with a configurable hotkey
- Captures across multiple monitors and lets you switch displays in the rewind overlay
- Keeps recent history at full detail, then compacts older history automatically
- Lets you keep between 30 minutes and 24 hours of rewind history
- Lets you search indexed text across your retained history from the overlay, with matching words highlighted in the frame preview
- Drag over a rewind frame to OCR on-screen text and copy the cleaned result to the clipboard
- Save the current frame with `⌘S`, or hold `⌘` and drag to save just a region — to a folder of your choice, the clipboard, or both
- Adapts capture behaviour when your Mac is on battery, idle, or under thermal pressure
- Stays out of the way with no Dock icon, and can hide its menu bar item if you prefer shortcuts

## Requirements

- macOS 15 or later
- Screen Recording permission

## Using JustNow

1. Download and open JustNow.
2. Grant Screen Recording permission when macOS asks.
3. Let it run in the menu bar.
4. Press `⌘⌥J` to open the rewind timeline, or `⌘⌥⇧J` to pause or resume recording.
5. Scroll or drag to move through recent history.
6. Press `Tab` in the overlay to switch monitors when multiple displays are connected.
7. Press `/` in the overlay to search indexed text across your retained history and jump through highlighted matches.
8. Drag over visible text in the current frame to copy it from OCR.
9. Press `⌘S` to save the current frame, or hold `⌘` and drag to save just that region. Click the resulting toast to reveal the file in Finder. The overlay's `…` menu also has a **Save Region…** item that primes the next drag for a region capture, so you can use it without learning the shortcut.
10. Press `Escape` to close the overlay.

If Screen Recording already looks enabled but JustNow still cannot capture after switching between differently signed builds, remove the `JustNow` entry in **System Settings → Privacy & Security → Screen Recording**, then relaunch and allow it again.

### Saving screenshots

Saved screenshots come from JustNow's rewind history rather than a fresh screen capture, so they aren't pixel-identical to `⇧⌘3`:

- **Format**: JPEG, using the same compression as the rewind history.
- **Resolution**: full pixel density when plugged in. Halved when capturing on battery or in Low Power Mode for performance — change this in **Settings → Capture**.
- **Destination**: by default, JustNow saves to your `com.apple.screencapture` location (Desktop unless you've changed it system-wide). You can pick a different folder, copy to the clipboard, or both, in **Settings → Screenshot save location**.

## Settings

You can adjust:

- capture interval
- rewind history length
- full-detail window for the newest history
- where saved screenshots go (folder, clipboard, or both) and a custom save folder
- play a copied-text sound after OCR succeeds
- play a system shutter sound on screenshot save
- show a text-grab debug preview of the OCR crop
- automatic power saving behaviour
- launch on startup
- hide the menu bar item
- open, pause or resume, and close shortcuts

## Privacy

JustNow has no telemetry: your screen history, indexed text, and settings never leave your Mac.

To help debug capture issues, JustNow keeps a small local diagnostics log at `~/Library/Logs/JustNow/`. It records capture lifecycle events (starts, stops, errors, sleep/lock transitions) and occasional aggregate capture/storage measurements such as frame counts, logical JPEG/metadata event-byte totals, queue peaks, and bounded comparison coverage. These logical event sizes are not measurements of filesystem growth, physical device writes, SSD wear, or NAND writes. Settings separately reports allocated SQLite/WAL space where macOS exposes it reliably. JustNow never records screen content, recognised text, image bytes, file paths, display names or IDs, or perceptual hashes. The log is capped at about 1 MB, is never transmitted anywhere, and you can delete it at any time.

The only network requests JustNow makes are update checks via Sparkle.

## Building From Source

See [Local Development](Docs/local-development.md) for focused tests, signing checks, safe replacement, and Screen Recording troubleshooting.

For a local install, first gracefully quit any running JustNow and wait for it to exit. This helper rebuilds, replaces, and attempts to launch `/Applications/JustNow.app`; it may use Developer ID signing. Restarting clears memory-only recent detail, so this is not a build-only check:

```bash
./Scripts/local-install-app.sh
```

To build without signing or installing:

```bash
xcodebuild build -project JustNow.xcodeproj -scheme JustNow \
  -configuration Release -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM=""
```

To run the app-hosted test suite without replacing the installed app:

```bash
xcodebuild test -project JustNow.xcodeproj -scheme JustNow \
  -destination 'platform=macOS' -derivedDataPath build-tests-unsigned \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM=""
```

## Licence

[MIT](./LICENSE)
