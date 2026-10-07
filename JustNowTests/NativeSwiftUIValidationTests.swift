import AppKit
import Carbon.HIToolbox
import ServiceManagement
import Sparkle
import SwiftUI
import XCTest
@testable import JustNow

/// Exercises AppKit dispatch and hosted SwiftUI controls using disposable data only.
@MainActor
final class NativeSwiftUIValidationTests: XCTestCase {
    private var temporaryURLs: [URL] = []
    private var preferenceDomains: [String] = []
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        windows.removeAll()
        for domain in preferenceDomains { UserDefaults.standard.removePersistentDomain(forName: domain) }
        for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    func testSearchCaretScrubRefocusAndSubmitWithoutActivatingWindow() async throws {
        let panel = NativeValidationNonActivatingPanel(
            contentRect: NSRect(x: -10000, y: -10000, width: 1280, height: 720),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        windows.append(panel)
        try requireNonActivating(panel)

        let directory = try temporaryDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let store = try FrameStore(directory: directory)
        let now = Date()
        for index in 0..<4 {
            let image = try XCTUnwrap(TestImageFactory.makeSolidImage(width: 16, height: 16, level: 100))
            _ = try await store.saveFrame(image, timestamp: now.addingTimeInterval(Double(index * 10 - 40)),
                hash: UInt64(index + 1), displayID: nil, displayName: "Synthetic display")
        }
        let buffer = try await FrameBuffer(retentionPolicy: .default24Hours, storageDirectory: directory,
            diagnosticsLog: nil, frameRepository: DiskFrameRepository(frameStore: store), historyStorageMode: .allDisk)
        let cache = buffer.textCache
        for entry in buffer.getTimelineEntries() {
            await buffer.textCache.setText("synthetic focus", for: entry.frame.id, timestamp: entry.frame.timestamp)
        }
        let vm = OverlayViewModel(timelineEntries: buffer.getTimelineEntries(), frameBuffer: buffer,
            recentTimelineWindow: 300, rewindHistoryOption: .twentyFourHours, availableDisplays: [],
            activeDisplay: nil, primaryDisplayID: nil, timelineReferenceDate: now,
            onDismiss: {}, onOpenSettings: {})
        vm.isSearching = true
        vm.searchQuery = "synthetic"
        vm.performSearch(immediately: true)
        let domain = "sg.tk.JustNow.NativeValidation.\(UUID())"
        preferenceDomains.append(domain)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let host = NSHostingView(rootView: ContentAreaView(viewModel: vm)
            .frame(width: 1280, height: 720).defaultAppStorage(defaults))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 1280, height: 720)
        panel.contentView = host
        // Runs after local strong references leave scope and before existing
        // tearDown deletes the fixture. Wait on ownership, not a fixed delay.
        addTeardownBlock { @MainActor [weak host, weak vm, weak buffer, weak store, weak cache] in
            let deadline = ContinuousClock.now.advanced(by: .seconds(6))
            while (host != nil || vm != nil || buffer != nil || store != nil || cache != nil),
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(host == nil && vm == nil && buffer == nil && store == nil && cache == nil,
                          "Synthetic hosted view and storage must release before fixture cleanup")
        }
        defer {
            vm.prepareForDismissal()
            vm.setTextGrabCancellationHandler(nil)
            panel.endEditing(for: nil)
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        panel.orderBack(nil)
        try await waitUntil { vm.searchResults.count == 4 && !vm.isSearchLoading }
        host.layoutSubtreeIfNeeded()
        try await waitUntil { self.editableField(in: host) != nil }
        try requireNonActivating(panel)

        // A non-key panel need not honor initial automatic focus. Set up the
        // real hosted field once; subsequent transitions must be request-driven.
        if !(panel.firstResponder is NSTextView) {
            XCTAssertTrue(panel.makeFirstResponder(try XCTUnwrap(editableField(in: host))))
        }
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
        XCTAssertTrue(editor.isEditable)
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        vm.goToEnd()
        panel.sendEvent(try key(kVK_LeftArrow, window: panel, characters: "\u{F702}"))
        XCTAssertEqual(editor.selectedRange().location, 5)
        XCTAssertEqual(vm.selectedIndex, 3, "Editing arrows must not rewind")
        try requireNonActivating(panel)

        // Real SliderTrack drag at one-quarter: 40-point outer horizontal
        // padding, 8-point inner padding, bottom padding50 and track offset12.
        let location = NSPoint(x: 48 + (1280 - 96) * 0.25, y: 58)
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        NSApp.postEvent(try mouse(.leftMouseUp), atStart: false)
        panel.sendEvent(try mouse(.leftMouseDown))
        try await waitUntil { vm.selectedIndex == 1 && (panel.firstResponder as? NSTextView)?.isEditable != true }
        try requireNonActivating(panel)
        let timelineResponder = try XCTUnwrap(panel.firstResponder)

        vm.focusSearch()
        try await waitUntil { (panel.firstResponder as? NSTextView)?.isEditable == true }
        try requireNonActivating(panel)
        XCTAssertEqual(vm.selectedIndex, 1, "Refocusing must preserve the selected result")
        panel.sendEvent(try key(kVK_Return, window: panel, characters: "\r"))
        try await waitUntil { panel.firstResponder === timelineResponder }
        try requireNonActivating(panel)
        XCTAssertFalse((panel.firstResponder as? NSTextView)?.isEditable == true)
        XCTAssertTrue(vm.isSearching, "Submission enters browsing without closing search")
        XCTAssertEqual(vm.searchQuery, "synthetic")
        XCTAssertEqual(vm.searchResults.count, 4)

        // No shown controller/monitor: native focus and field submission are
        // tested here; keyboard resolver dispatch has its own unit tests.
        await buffer.flushCaches()
    }

    private func requireNonActivating(_ panel: NSPanel) throws {
        guard !panel.isKeyWindow, !panel.isMainWindow,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            panel.orderOut(nil)
            throw XCTSkip("Native focus probe requires a non-key/non-main, non-frontmost test host")
        }
    }

    private func editableField(in root: NSView) -> NSTextField? {
        if let field = root as? NSTextField, field.isEditable { return field }
        for child in root.subviews { if let field = editableField(in: child) { return field } }
        return nil
    }

    func testNativeOverlayEditorAndOtherWindowEvents() async throws {
        let directory = try temporaryDirectory()
        let store = try FrameStore(directory: directory)
        for index in 0..<4 {
            let image = try XCTUnwrap(TestImageFactory.makeSolidImage(width: 16, height: 16, level: UInt8(60 + index * 40)))
            _ = try await store.saveFrame(image, timestamp: Date().addingTimeInterval(Double(index * 20 - 100)),
                hash: UInt64(index + 1), displayID: nil, displayName: "Synthetic display")
        }
        let buffer = try await FrameBuffer(retentionPolicy: .default24Hours, storageDirectory: directory,
            diagnosticsLog: nil, frameRepository: DiskFrameRepository(frameStore: store), historyStorageMode: .allDisk)
        let controller = OverlayWindowController(frameBuffer: buffer,
            dismissShortcutKeyCode: kVK_Escape, dismissShortcutModifiers: 0, onOpenSettings: {})
        await controller.showOverlay(recentTimelineWindow: 300, rewindHistoryOption: .twentyFourHours,
            activeDisplay: nil, availableDisplays: [])
        defer { controller.hideOverlay() }
        let vm = try XCTUnwrap(controller.viewModel)
        let window = try XCTUnwrap(NSApp.windows.first { $0 is OverlayWindow })
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        editor.string = "Synthetic editor text"
        editor.isEditable = true
        window.contentView = editor
        vm.isSearching = true
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 8, length: 0))
        let initial = vm.selectedIndex
        NSApp.sendEvent(try key(kVK_LeftArrow, window: window, characters: "\u{F702}"))
        XCTAssertEqual(vm.selectedIndex, initial)
        XCTAssertEqual(editor.selectedRange().location, 7)
        XCTAssertTrue(window.makeFirstResponder(window))
        NSApp.sendEvent(try key(kVK_LeftArrow, window: window, characters: "\u{F702}"))
        XCTAssertEqual(vm.selectedIndex, initial - 1, "Unfocused search navigates history through the real monitor")

        let other = makeWindow(size: NSSize(width: 300, height: 150))
        other.contentView = NSTextView(frame: other.contentView!.bounds)
        let selected = vm.selectedIndex
        NSApp.sendEvent(try key(kVK_RightArrow, window: other, characters: "\u{F703}"))
        XCTAssertEqual(vm.selectedIndex, selected)
        vm.isCommandHeld = false
        NSApp.sendEvent(try key(kVK_Command, window: other, flags: .command, type: .flagsChanged))
        XCTAssertFalse(vm.isCommandHeld)
        NSApp.sendEvent(try key(kVK_Command, window: window, flags: .command, type: .flagsChanged))
        XCTAssertTrue(vm.isCommandHeld)
        NSApp.sendEvent(try key(kVK_Command, window: other, type: .flagsChanged))
        XCTAssertTrue(vm.isCommandHeld)
        let outsideScroll = NativeValidationScrollEvent()
        outsideScroll.targetWindow = other
        NSApp.sendEvent(outsideScroll)
        XCTAssertEqual(vm.selectedIndex, selected)
        let overlayScroll = NativeValidationScrollEvent()
        overlayScroll.targetWindow = window
        NSApp.sendEvent(overlayScroll)
        XCTAssertNotEqual(vm.selectedIndex, selected, "Positive control proves the scroll monitor ran")
        controller.hideOverlay()
        await buffer.flushCaches()
    }

    func testRecorderTabTraversalAfterCaptureAndCancel() throws {
        let window = makeWindow(size: NSSize(width: 420, height: 180))
        let before = NSTextField(frame: NSRect(x: 20, y: 120, width: 160, height: 24))
        let recorder = RecorderNSView(frame: NSRect(x: 20, y: 75, width: 180, height: 30))
        let after = NSTextField(frame: NSRect(x: 20, y: 25, width: 160, height: 24))
        for view in [before, recorder, after] { window.contentView?.addSubview(view) }
        window.autorecalculatesKeyViewLoop = false
        before.nextKeyView = recorder
        recorder.nextKeyView = after
        after.nextKeyView = before
        XCTAssertTrue(window.makeFirstResponder(before))
        NSApp.sendEvent(try key(kVK_Tab, window: window, characters: "\t"))
        XCTAssertTrue(window.firstResponder === recorder)
        NSApp.sendEvent(try key(kVK_Space, window: window, characters: " "))
        XCTAssertEqual(recorder.accessibilityValue() as? String, "Press shortcut")
        NSApp.sendEvent(try key(kVK_F1, window: window, flags: [.command, .capsLock, .function], characters: "\u{F704}"))
        XCTAssertEqual(recorder.accessibilityValue() as? String, "⌘F1")
        XCTAssertTrue(window.firstResponder === recorder)
        NSApp.sendEvent(try key(kVK_Tab, window: window, characters: "\t"))
        XCTAssertTrue((window.firstResponder as? NSTextView)?.delegate === after)
        NSApp.sendEvent(try key(kVK_Tab, window: window, flags: .shift, characters: "\u{19}"))
        XCTAssertTrue(window.firstResponder === recorder)
        XCTAssertTrue(recorder.accessibilityPerformPress())
        XCTAssertEqual(recorder.accessibilityRole(), .button)
        XCTAssertEqual(recorder.accessibilityValue() as? String, "Press shortcut")
        NSApp.sendEvent(try key(kVK_Escape, window: window, characters: "\u{1B}"))
        XCTAssertTrue(window.firstResponder === recorder)
        XCTAssertEqual(recorder.accessibilityValue() as? String, "⌘F1")
        NSApp.sendEvent(try key(kVK_Tab, window: window, flags: .shift, characters: "\u{19}"))
        XCTAssertTrue((window.firstResponder as? NSTextView)?.delegate === before)
    }

    func testExternalUpdaterChangesReachBothExistingSettingsHosts() async throws {
        let updater = try makeUpdater()
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        let context = SettingsContext(updater: updater)
        let hosts = try makeSettingsHosts(context)
        try await waitUntil { hosts.allSatisfy { self.switchStates($0) == [.off, .on, .off, .off] } }
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = true
        try await waitUntil { hosts.allSatisfy { self.switchStates($0) == [.off, .on, .on, .on] } }
        XCTAssertTrue(context.automaticallyChecksForUpdates)
        XCTAssertTrue(context.automaticallyDownloadsUpdates)

        let replacement = try makeUpdater()
        replacement.automaticallyChecksForUpdates = false
        replacement.automaticallyDownloadsUpdates = false
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyChecksForUpdates = true
        context.updater = replacement
        try await waitUntil { hosts.allSatisfy { self.switchStates($0) == [.off, .on, .off, .off] } }
        XCTAssertFalse(context.automaticallyChecksForUpdates, "Old updater callbacks cannot overwrite its replacement")
        replacement.automaticallyChecksForUpdates = true
        try await waitUntil { hosts.allSatisfy { self.switchStates($0) == [.off, .on, .on, .off] } }
        context.updater = nil
        try await waitUntil { hosts.allSatisfy { self.switchStates($0) == [.off, .on, .off, .off] } }
        XCTAssertFalse(context.canCheckForUpdates)
    }

    func testLoginSnapshotRefreshSetterAndReplacementReachBothHosts() async throws {
        let service = NativeValidationLoginService()
        let context = SettingsContext(launchAtLoginManager: LaunchAtLoginManager(service: service))
        let hosts = try makeSettingsHosts(context)
        try await waitUntil { hosts.allSatisfy { self.switchStates($0).first == .off } }
        service.syntheticStatus = .requiresApproval
        context.refreshLaunchAtLoginState()
        try await waitUntil { hosts.allSatisfy { self.switchStates($0).first == .on } }
        XCTAssertTrue(context.launchAtLoginEnabled)
        _ = try context.setLaunchAtLoginEnabled(false)
        try await waitUntil { hosts.allSatisfy { self.switchStates($0).first == .off } }
        XCTAssertEqual(service.unregisterCalls, 1)
        let replacement = NativeValidationLoginService()
        replacement.syntheticStatus = .enabled
        context.launchAtLoginManager = LaunchAtLoginManager(service: replacement)
        try await waitUntil { hosts.allSatisfy { self.switchStates($0).first == .on } }
        context.launchAtLoginManager = nil
        try await waitUntil { hosts.allSatisfy { self.switchStates($0).first == .off } }
    }

    private func makeSettingsHosts(_ context: SettingsContext) throws -> [NSView] {
        let domain = "sg.tk.JustNow.NativeValidation.\(UUID().uuidString)"
        preferenceDomains.append(domain)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(true, forKey: AppStorageKey.showMenuBarIcon)
        return (0..<2).map { _ in
            let host = NSHostingView(rootView: SettingsView(context: context).defaultAppStorage(defaults))
            let window = makeWindow(size: NSSize(width: 660, height: 520))
            window.contentView = host
            return host
        }
    }

    private func switchStates(_ root: NSView) -> [NSControl.StateValue] {
        // General tab order: launch, menu bar, automatic checks, automatic downloads.
        // Inspect native control values; cached NSView bitmaps can retain old switch images.
        if let control = root as? NSSwitch { return [control.state] }
        return root.subviews.flatMap(switchStates)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out waiting for native control state")
    }

    private func makeUpdater() throws -> SPUUpdater {
        let id = "sg.tk.JustNow.NativeValidation.\(UUID().uuidString)"
        preferenceDomains.append(id)
        let bundleURL = try temporaryDirectory().appendingPathComponent("Synthetic.app")
        let contents = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": "Synthetic validation",
            "CFBundleVersion": "1", "CFBundlePackageType": "APPL", "SUEnableAutomaticChecks": false,
            "SUAllowsAutomaticUpdates": true]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        // Never start this updater: no network, prompts or real application preferences.
        return SPUUpdater(hostBundle: bundle, applicationBundle: bundle,
            userDriver: SPUStandardUserDriver(hostBundle: bundle, delegate: nil), delegate: nil)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NativeValidation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    private func makeWindow(size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: size),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Synthetic native validation"
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func key(_ code: Int, window: NSWindow, flags: NSEvent.ModifierFlags = [],
                     characters: String = "", type: NSEvent.EventType = .keyDown) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: UInt16(code)))
    }
}

private final class NativeValidationNonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class NativeValidationScrollEvent: NSEvent {
    weak var targetWindow: NSWindow?
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { targetWindow }
    override var windowNumber: Int { targetWindow?.windowNumber ?? 0 }
    override var locationInWindow: NSPoint { NSPoint(x: 20, y: 20) }
    override var scrollingDeltaX: CGFloat { 0 }
    override var scrollingDeltaY: CGFloat { 1 }
    override var hasPreciseScrollingDeltas: Bool { false }
    override var phase: NSEvent.Phase { [] }
    override var momentumPhase: NSEvent.Phase { [] }
}

/// Never calls ServiceManagement; only the injected in-memory service changes.
private final class NativeValidationLoginService: SMAppService {
    var syntheticStatus: SMAppService.Status = .notRegistered
    var unregisterCalls = 0
    override var status: SMAppService.Status { syntheticStatus }
    override func register() throws { syntheticStatus = .enabled }
    override func unregister() throws {
        unregisterCalls += 1
        syntheticStatus = .notRegistered
    }
}
