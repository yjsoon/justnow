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
9. Press `Escape` to close the overlay.

If Screen Recording already looks enabled but JustNow still cannot capture after switching between differently signed builds, remove the `JustNow` entry in **System Settings → Privacy & Security → Screen Recording**, then relaunch and allow it again.

## Settings

You can adjust:

- capture interval
- rewind history length
- full-detail window for the newest history
- play a copied-text sound after OCR succeeds
- show a text-grab debug preview of the OCR crop
- automatic power saving behaviour
- launch on startup
- hide the menu bar item
- open, pause or resume, and close shortcuts

## Building From Source

For a normal local install:

```bash
./Scripts/local-install-app.sh
```

To build without installing:

```bash
xcodebuild -scheme JustNow -configuration Release -derivedDataPath build
```

To run the test suite:

```bash
xcodebuild test -project JustNow.xcodeproj -scheme JustNow -destination 'platform=macOS'
```

## Licence

[MIT](./LICENSE)
