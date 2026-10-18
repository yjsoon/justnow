# Search Feature Implementation - Handoff Document

## What Was Implemented

### Core Feature: Index-Only Search with Full History OCR

1. **Ungated Search Feature** (`AppDelegate.swift`)
   - `FeatureFlags.isSearchEnabled = true` (line ~156)
   - OCR indexing always enabled via `var ocrIndexEnabled = true` in `computeCapturePolicy()` (line ~1126)

2. **FrameBuffer OCR Queue Changes** (`FrameBuffer.swift`)
   - `SearchIndexStatus` struct tracks: total frames, indexed frames, queued frames
   - `enqueueStoredFramesForBackgroundOCR()` — queues ALL retained frames, not just recent
   - Removed `trimOCRIndexQueueIfNeeded()` — no longer drops old frames from queue
   - Alternating dequeue strategy: alternates between newest and oldest frames via `shouldDequeueNewestOCRFrame` toggle
   - Removed `maxFrameAge` skip in `runBackgroundOCRIndexingLoop()` — all frames get indexed

3. **Index-Only Search** (`OverlayView.swift`)
   - `performSearch()` queries `TextCache.searchFrameIDs()` directly — no query-time OCR
   - Removed `SearchOCRBatchResult` enum (no longer needed)
   - Removed `searchableFrames` property — search queries all retained frames
   - Results reversed to chronological order in `performSearch()` to match overlay assumptions
   - Initial selection is `finalResults.count - 1` (newest match in chronological array)

4. **Search Result Ordering** (`TextCache.swift`)
   - Changed from `ORDER BY bm25(frame_text_fts), timestamp DESC` to `ORDER BY frame_text.timestamp DESC`
   - Returns newest matches first from DB, reversed to chronological in UI layer

5. **Arrow Key Navigation** (`OverlayWindowController.swift`)
   - Left/right arrows always navigate frames/matches, even when search field focused
   - No longer passed to text field for caret movement (intentional per user request)

6. **Index Status UI** (`OverlayView.swift`)
   - `SearchBarView` shows: "X found · Y% indexed" or just "Y% indexed" when idle
   - Polls status every 2s via `refreshIndexStatus()` while search bar visible

7. **First-Run OCR Speed-up** (`FrameBuffer.swift`, `FrameStore.swift`, `ThumbnailGenerator.swift`, `AppDelegate.swift`)
   - Background OCR now processes multiple frames per pass (`concurrentJobs`) instead of one-at-a-time
   - Search indexing decodes each frame at its captured resolution. An earlier 800–1200px downscaled decode was removed because fast OCR could not read normal-size UI text at that size
   - Concurrency scales down on battery, idle, and thermal pressure

## Current Behavior

### How Indexing Works
- **When**: Continuously in background via `Task(priority: .utility)`
- **Where**: `runBackgroundOCRIndexingLoop()` in `FrameBuffer.swift`
- **What**: Processes small batches of frames concurrently with a configurable interval
- **Restart**: Self-restarting — when queue empties, loop restarts if new frames arrive
- **Pause conditions**: Only stops when battery is critically low OR thermal state is `.critical`
- **Throttle conditions**: Slows down and reduces OCR parallelism on battery, idle, or thermal `.serious`

### Search Flow
1. User types query, presses Return
2. `performSearch()` queries `TextCache` via FTS5
3. Results returned newest-first from DB
4. `performSearch()` reverses to chronological order
5. `selectedIndex` set to last element (newest match)
6. Left arrow → older match, Right arrow → newer match

### First-Run Experience
- On first launch with existing history: indexes ALL retained frames
- Initial indexing is faster than before due to batched OCR
- Once caught up: stays near 100% indexed with minimal CPU

## Known Limitations / User Concerns

1. **Thumbnails are 200px** — too small for reliable OCR (confirmed in `ThumbnailGenerator.swift`)
2. **Initial catch-up still depends on backlog size** — faster, but very large histories will still take time
3. **1x captures read small text poorly** — idle, low-battery and thermal policies capture at scale 1, where fast OCR misses some 11–12pt text

## What Was Chosen

- **Parallel OCR**: implemented with background batches of up to 3 frames in normal conditions
- **Separate OCR cache at 800–1200px**: not implemented
- **Downscaled decode for OCR**: tried and removed; fast OCR needs about two pixels per point
- **Use existing thumbnails**: rejected, still too small (200px max)

## Files Modified (Summary)

| File | Key Changes |
|------|-------------|
| `JustNow/Capture/FrameBuffer.swift` | Unbounded OCR queue, alternating dequeue, `SearchIndexStatus`, full-history indexing, batched background OCR |
| `JustNow/AppDelegate.swift` | Ungated search, always-enable OCR indexing, OCR batch size / image size policy |
| `JustNow/UI/OverlayView.swift` | Index-only `performSearch()`, chronological result ordering, index status UI |
| `JustNow/UI/OverlayWindowController.swift` | Arrow key handling (always navigate), simplified `showOverlay()` |
| `JustNow/Storage/TextCache.swift` | Recency-first search ordering |

## Current State

- ✅ Search is ungated and functional
- ✅ Index-only search (instant, no query-time OCR)
- ✅ Full retained history indexed
- ✅ Results show newest match first
- ✅ Arrow keys navigate results
- ✅ First-run indexing now uses concurrent reduced-size OCR
- ⚠️ Very large backlogs may still take time to catch up
- ⚠️ No precise before/after benchmark has been captured yet

## Next Steps for Incoming Agent

1. Measure actual catch-up throughput in a large real-world history and compare against the old serial path
2. Tune `concurrentJobs`, `minimumInterval`, and `searchImageMaxPixelSize` if CPU or battery impact is still too high
3. Consider a dedicated persisted OCR image cache only if reduced-size decode from disk is still a measurable bottleneck
4. Consider surfacing telemetry in a debug workflow if more search performance tuning is needed
