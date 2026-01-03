# Claude Code Guide: Build JustNow - Mac Screenshot Buffer App

## Project Overview

Build a native macOS menu bar app called **JustNow** that continuously captures screenshots and lets the user scroll back through the last 5-10 minutes of screen history via a hotkey-triggered fullscreen overlay.

**Core user flow:**
1. App runs silently in menu bar, capturing screenshots every 1-2 seconds
2. User presses hotkey (e.g., Cmd+Option+R)
3. Fullscreen overlay appears with current screenshot and a horizontal timeline scrubber
4. User scrolls/drags backwards through time to find what they need
5. Press Escape or click outside to dismiss

## Project Setup (ALREADY DONE)

The Xcode project has already been created with these settings:
- **Product Name:** JustNow
- **Bundle Identifier:** sg.tk.JustNow
- **Team:** Tinkertanker
- **Interface:** SwiftUI
- **Language:** Swift
- **App Sandbox:** Disabled (required for ScreenCaptureKit)
- **LSUIElement:** YES (menu bar only, no dock icon)
- **NSScreenCaptureUsageDescription:** Added

## Build Tool: XcodeBuildMCP

Use XcodeBuildMCP to build and run the project. Key commands:
- Build: `xcodebuild -scheme JustNow -project JustNow.xcodeproj build`
- Run: Build first, then launch from derived data or use `open` on the .app
- Clean: `xcodebuild -scheme JustNow -project JustNow.xcodeproj clean`

When you encounter build errors, read them carefully - Xcode error messages are usually specific about what's wrong.

## Technical Requirements

**Target:** macOS 13+ (Ventura), Swift 5.9+, SwiftUI for UI

**Key constraints:**
- Storage budget: configurable, default 10GB
- Time window: last 5-10 minutes at full density, exponential decay for older frames
- Battery-conscious: must use hardware acceleration, adaptive capture rate on battery
- Privacy: all data stays local, no network, no AI/OCR (user will add separately if wanted)

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    ScreenCaptureKit                         │
│              (1-2 second interval capture)                  │
└─────────────────────┬───────────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────────┐
│                 Perceptual Hash Filter                      │
│            (skip unchanged frames, ~30-50% savings)         │
└─────────────────────┬───────────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────────┐
│                  Ring Buffer (RAM)                          │
│           (last 30s as raw CVPixelBuffer refs)              │
└─────────────────────┬───────────────────────────────────────┘
                      │ Background thread
┌─────────────────────▼───────────────────────────────────────┐
│              VideoToolbox H.264/HEVC Encoder                │
│        (5-minute chunks, keyframe every 60 frames)          │
└─────────────────────┬───────────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────────┐
│                Tiered Storage + SQLite                      │
│      (exponential decay pruning, frame index metadata)      │
└─────────────────────────────────────────────────────────────┘
```

## Implementation Plan

### Phase 1: Add Dependencies & First Capture

**Add HotKey package via SPM:**
In Xcode: File → Add Package Dependencies → Enter `https://github.com/soffes/HotKey`

**First milestone:** Capture a single screenshot using ScreenCaptureKit and log that it worked.

```swift
// Core capture setup - ScreenCaptureKit is the ONLY viable API
// CGWindowListCreateImage is deprecated as of macOS 15

import ScreenCaptureKit

class ScreenCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let captureQueue = DispatchQueue(label: "sg.tk.justnow.capture", qos: .utility)
    
    func startCapture() async throws {
        // Request permission first
        guard CGRequestScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }
        
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }
        
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        
        // CRITICAL: Low frame rate for battery efficiency
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 fps
        config.width = display.width * 2   // Retina resolution
        config.height = display.height * 2
        config.queueDepth = 3
        config.showsCursor = true
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        
        stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream?.startCapture()
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        
        // pixelBuffer is IOSurface-backed - GPU memory, efficient
        processFrame(pixelBuffer, timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
    
    private func processFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        // TODO: Pass to FrameBuffer
        print("Captured frame at \(timestamp.seconds)")
    }
}

enum CaptureError: Error {
    case permissionDenied
    case noDisplay
}
```

### Phase 2: Frame Storage with Perceptual Hashing

Implement a ring buffer that stores recent frames and skips near-identical ones:

```swift
import CoreVideo

class FrameBuffer {
    struct StoredFrame {
        let id: UUID
        let timestamp: Date
        let pixelBuffer: CVPixelBuffer
        let hash: UInt64
    }
    
    private var frames: [StoredFrame] = []
    private var lastHash: UInt64?
    private let hashThreshold: Int = 5  // Hamming distance threshold
    
    func addFrame(_ pixelBuffer: CVPixelBuffer, timestamp: Date) {
        let hash = computePerceptualHash(pixelBuffer)
        
        // Skip if too similar to previous frame
        if let last = lastHash, hammingDistance(hash, last) <= hashThreshold {
            return
        }
        
        let frame = StoredFrame(
            id: UUID(),
            timestamp: timestamp,
            pixelBuffer: pixelBuffer,
            hash: hash
        )
        
        frames.append(frame)
        lastHash = hash
        
        // Trigger pruning if needed
        pruneOldFrames()
    }
    
    // Simple pHash implementation - or use CocoaImageHashing library
    private func computePerceptualHash(_ buffer: CVPixelBuffer) -> UInt64 {
        // 1. Resize to 32x32
        // 2. Convert to grayscale
        // 3. Compute DCT
        // 4. Take top-left 8x8 (excluding DC)
        // 5. Compute median, threshold to bits
        // Return 64-bit hash
        // ... implementation details ...
    }
}
```

### Phase 3: Exponential Decay Retention

Implement tiered retention that keeps more recent frames at higher density:

```swift
struct RetentionTier {
    let maxAge: TimeInterval      // Frames older than this get pruned to next tier
    let keepEveryNth: Int         // Keep every Nth frame when demoting
}

class RetentionManager {
    // Retention policy: more recent = denser
    static let tiers: [RetentionTier] = [
        RetentionTier(maxAge: 30, keepEveryNth: 1),      // 0-30s: keep all
        RetentionTier(maxAge: 300, keepEveryNth: 2),     // 30s-5m: every 2nd
        RetentionTier(maxAge: 600, keepEveryNth: 5),     // 5-10m: every 5th
        RetentionTier(maxAge: 3600, keepEveryNth: 30),   // 10m-1h: every 30th
    ]
    
    func pruneFrames(frames: inout [StoredFrame], currentTime: Date) {
        var result: [StoredFrame] = []
        var tierFrameCounts: [Int] = Array(repeating: 0, count: Self.tiers.count)
        
        // Process newest to oldest
        for frame in frames.reversed() {
            let age = currentTime.timeIntervalSince(frame.timestamp)
            
            // Find which tier this frame belongs to
            guard let tierIndex = Self.tiers.firstIndex(where: { age <= $0.maxAge }) else {
                continue  // Too old, drop it
            }
            
            let tier = Self.tiers[tierIndex]
            tierFrameCounts[tierIndex] += 1
            
            // Keep if it's the Nth frame for this tier
            if tierFrameCounts[tierIndex] % tier.keepEveryNth == 0 {
                result.append(frame)
            }
        }
        
        frames = result.reversed()
    }
}
```

### Phase 4: Menu Bar App Structure

Set up the app as a menu bar-only application:

```swift
import SwiftUI
import HotKey

@main
struct JustNowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var captureManager: ScreenCaptureManager!
    private var frameBuffer: FrameBuffer!
    private var overlayController: OverlayWindowController?
    private var hotKey: HotKey?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupHotKey()
        setupCapture()
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "JustNow")
            button.image?.isTemplate = true
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Timeline", action: #selector(showOverlay), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }
    
    private func setupHotKey() {
        // Cmd+Option+R to show overlay
        hotKey = HotKey(key: .r, modifiers: [.command, .option])
        hotKey?.keyDownHandler = { [weak self] in
            self?.showOverlay()
        }
    }
    
    private func setupCapture() {
        captureManager = ScreenCaptureManager()
        frameBuffer = FrameBuffer()
        
        Task {
            do {
                try await captureManager.startCapture()
            } catch {
                // Show alert about permission
                showPermissionAlert()
            }
        }
    }
    
    @objc private func showOverlay() {
        if overlayController == nil {
            overlayController = OverlayWindowController(frameBuffer: frameBuffer)
        }
        overlayController?.showOverlay()
    }
    
    @objc private func showSettings() {
        // TODO: Open settings window
    }
    
    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "JustNow needs screen recording permission to capture your screen history. Please grant permission in System Settings → Privacy & Security → Screen Recording."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }
}
```

### Phase 5: Fullscreen Overlay UI

Create a borderless fullscreen window with timeline scrubber:

```swift
import SwiftUI
import AppKit

class OverlayWindowController {
    private var panel: NSPanel?
    private let frameBuffer: FrameBuffer
    
    init(frameBuffer: FrameBuffer) {
        self.frameBuffer = frameBuffer
    }
    
    func showOverlay() {
        guard let screen = NSScreen.main else { return }
        
        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.9)
        panel.hasShadow = false
        
        let overlayView = OverlayView(
            frames: frameBuffer.getFrames(),
            onDismiss: { [weak self] in self?.hideOverlay() }
        )
        
        panel.contentView = NSHostingView(rootView: overlayView.ignoresSafeArea())
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        self.panel = panel
    }
    
    func hideOverlay() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct OverlayView: View {
    let frames: [StoredFrame]
    let onDismiss: () -> Void
    
    @State private var selectedIndex: Int = 0
    @State private var showingThumbnails = true
    
    var body: some View {
        ZStack {
            // Background tap to dismiss
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
            
            VStack(spacing: 0) {
                // Main preview image
                if let frame = frames[safe: selectedIndex] {
                    FramePreviewView(pixelBuffer: frame.pixelBuffer)
                        .aspectRatio(contentMode: .fit)
                        .padding(40)
                }
                
                Spacer()
                
                // Timeline scrubber at bottom
                TimelineScrubber(
                    frames: frames,
                    selectedIndex: $selectedIndex
                )
                .frame(height: 120)
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
        .onExitCommand { onDismiss() }  // Escape key
        .gesture(
            DragGesture()
                .onChanged { value in
                    // Horizontal drag to scrub through time
                    let delta = Int(value.translation.width / 50)
                    selectedIndex = max(0, min(frames.count - 1, selectedIndex - delta))
                }
        )
    }
}

struct TimelineScrubber: View {
    let frames: [StoredFrame]
    @Binding var selectedIndex: Int
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(Array(frames.enumerated()), id: \.element.id) { index, frame in
                        ThumbnailView(
                            pixelBuffer: frame.pixelBuffer,
                            isSelected: index == selectedIndex,
                            timestamp: frame.timestamp
                        )
                        .id(index)
                        .onTapGesture { selectedIndex = index }
                    }
                }
                .padding(.horizontal, 20)
            }
            .onChange(of: selectedIndex) { newIndex in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }
}

struct ThumbnailView: View {
    let pixelBuffer: CVPixelBuffer
    let isSelected: Bool
    let timestamp: Date
    
    var body: some View {
        VStack(spacing: 4) {
            // Generate thumbnail from CVPixelBuffer
            Image(nsImage: thumbnailFromPixelBuffer(pixelBuffer, maxSize: 160))
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 160, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.white : Color.clear, lineWidth: 3)
                )
            
            Text(timeAgoString(from: timestamp))
                .font(.caption2)
                .foregroundColor(.white.opacity(0.7))
        }
    }
    
    private func timeAgoString(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 {
            return "\(seconds)s ago"
        } else {
            return "\(seconds / 60)m \(seconds % 60)s ago"
        }
    }
}

// Fast thumbnail generation using Core Graphics
func thumbnailFromPixelBuffer(_ buffer: CVPixelBuffer, maxSize: CGFloat) -> NSImage {
    let ciImage = CIImage(cvPixelBuffer: buffer)
    let context = CIContext(options: [.useSoftwareRenderer: false])
    
    let scale = maxSize / max(ciImage.extent.width, ciImage.extent.height)
    let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    
    guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
        return NSImage()
    }
    
    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
}
```

### Phase 6: Battery Optimisation

Implement power-aware capture settings:

```swift
import IOKit.ps

class PowerManager {
    static func isOnBattery() -> Bool {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        
        for source in sources {
            let info = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as! [String: Any]
            if let powerSource = info[kIOPSPowerSourceStateKey] as? String {
                return powerSource == kIOPSBatteryPowerValue
            }
        }
        return false
    }
}

extension ScreenCaptureManager {
    func updateForPowerState() async throws {
        let isOnBattery = PowerManager.isOnBattery()
        
        let config = SCStreamConfiguration()
        
        if isOnBattery {
            // Reduce capture frequency on battery
            config.minimumFrameInterval = CMTime(value: 2, timescale: 1)  // 0.5 fps
            // Could also reduce resolution here
        } else {
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 fps
        }
        
        try await stream?.updateConfiguration(config)
    }
}

// Prevent App Nap during capture
class AppNapPreventer {
    private var activityToken: NSObjectProtocol?
    
    func startActivity() {
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Screen capture active"
        )
    }
    
    func stopActivity() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }
}
```

### Phase 7 (Optional): Video Encoding for Long-term Storage

For storage beyond the immediate RAM buffer, encode frames to H.264/HEVC video chunks:

```swift
import AVFoundation
import VideoToolbox

class VideoChunkEncoder {
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    
    private let chunkDuration: TimeInterval = 300  // 5 minute chunks
    private var chunkStartTime: CMTime?
    private var frameCount: Int = 0
    
    func startNewChunk(width: Int, height: Int) throws -> URL {
        let outputURL = getChunkURL()
        
        assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,  // Better compression than H.264
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 500_000,        // 500 kbps (low for screenshots)
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoExpectedSourceFrameRateKey: 1,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel
            ]
        ]
        
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput?.expectsMediaDataInRealTime = true
        
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput!,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        
        assetWriter?.add(videoInput!)
        assetWriter?.startWriting()
        
        chunkStartTime = nil
        frameCount = 0
        
        return outputURL
    }
    
    func appendFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard let writer = assetWriter,
              let input = videoInput,
              let adaptor = pixelBufferAdaptor,
              writer.status == .writing,
              input.isReadyForMoreMediaData else { return }
        
        if chunkStartTime == nil {
            chunkStartTime = timestamp
            writer.startSession(atSourceTime: timestamp)
        }
        
        adaptor.append(pixelBuffer, withPresentationTime: timestamp)
        frameCount += 1
    }
    
    func finishChunk() async throws {
        videoInput?.markAsFinished()
        await assetWriter?.finishWriting()
    }
    
    private func getChunkURL() -> URL {
        let formatter = ISO8601DateFormatter()
        let filename = "chunk_\(formatter.string(from: Date())).mp4"
        return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }
}
```

## File Structure

```
JustNow/
├── JustNowApp.swift               # @main, App struct
├── AppDelegate.swift              # Menu bar setup, hotkey, lifecycle
├── Capture/
│   ├── ScreenCaptureManager.swift # ScreenCaptureKit wrapper
│   ├── FrameBuffer.swift          # In-memory frame storage
│   └── PerceptualHash.swift       # pHash implementation
├── Storage/
│   ├── RetentionManager.swift     # Exponential decay logic
│   ├── VideoChunkEncoder.swift    # H.264/HEVC encoding (optional)
│   └── StorageManager.swift       # Disk storage, cleanup
├── UI/
│   ├── OverlayWindowController.swift  # NSPanel management
│   ├── OverlayView.swift          # Main SwiftUI overlay
│   ├── TimelineScrubber.swift     # Horizontal thumbnail strip
│   ├── ThumbnailView.swift        # Individual frame thumbnail
│   └── SettingsView.swift         # Settings window
├── Utilities/
│   ├── PowerManager.swift         # Battery state detection
│   └── AppNapPreventer.swift      # Prevent system sleep
└── Resources/
    └── Info.plist                 # Already configured
```

## Info.plist (Already Configured)

These keys should already be set:
```xml
<key>LSUIElement</key>
<true/>

<key>NSScreenCaptureUsageDescription</key>
<string>JustNow needs screen recording permission to capture your screen history.</string>
```

## Testing Checklist

- [ ] Screen capture permission flow works correctly
- [ ] Frames captured at expected rate (1-2 fps)
- [ ] Perceptual hashing skips static frames
- [ ] Memory usage stays bounded (test with Activity Monitor)
- [ ] Overlay appears on hotkey press
- [ ] Timeline scrubbing is smooth with 300+ frames
- [ ] Escape key and outside click dismiss overlay
- [ ] App survives sleep/wake cycles
- [ ] Exponential decay pruning works correctly
- [ ] Battery drain is acceptable (<5% per hour)

## Performance Targets

- CPU usage during capture: <3%
- Memory for 10 minutes of frames: <500MB
- Overlay launch time: <200ms
- Timeline scroll: 60fps smooth
- Storage per hour (with video encoding): ~100MB

## Key Implementation Notes

1. **ScreenCaptureKit is mandatory** - `CGWindowListCreateImage` is deprecated as of macOS 15. ScreenCaptureKit provides hardware-accelerated capture with IOSurface-backed buffers (GPU memory, no CPU copy).

2. **Perceptual hashing saves 30-50% storage** - Desktop screenshots are often static (reading, thinking). Use pHash to detect near-identical frames and skip storing them.

3. **Video encoding is optional but recommended** - For just 5-10 minutes of history, raw CVPixelBuffer storage in RAM is fine. For longer retention, H.264/HEVC encoding achieves 100-500x compression.

4. **Timer coalescing matters for battery** - Never use precise timers for background capture. Add leeway to allow macOS to batch timer wake-ups.

5. **The overlay window is tricky** - Use NSPanel with `.screenSaver` level to appear above fullscreen apps. Handle activation, key events, and dismissal carefully.

## Reference Libraries

- **soffes/HotKey** (added via SPM) - Global hotkey registration
- **wulkano/Aperture** - Reference implementation for ScreenCaptureKit patterns (don't add as dependency, just for reference)
- **lihaoyun6/QuickRecorder** - Full menu bar screen recorder example (reference only)

## Getting Started

The project is already set up. Next steps:

1. **Add HotKey package** - File → Add Package Dependencies → `https://github.com/soffes/HotKey`
2. **Create the file structure** - Add the folders and Swift files as shown above
3. **Implement Phase 1** - Get basic screen capture working
4. **Implement Phase 4** - Get menu bar app structure working
5. **Implement Phase 2-3** - Frame buffer and retention
6. **Implement Phase 5** - Overlay UI
7. **Implement Phase 6** - Battery optimisation

Start by getting a minimal working version: menu bar icon → hotkey → captures one frame → shows it. Then iterate from there.
