import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import JustNow

@MainActor
final class KeyboardShortcutRecorderTests: XCTestCase {
    /// R3: exercise the real Settings wiring, not a delegate that pauses hotkeys itself.
    func testSettingsRecordingSuspendsBothCarbonHotKeysThroughReregistrationUntilEscape() async throws {
        let domain = "sg.tk.JustNow.RecorderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let modifiers = Int(NSEvent.ModifierFlags([.command, .option, .control, .shift]).rawValue)
        defaults.set(kVK_F18, forKey: AppStorageKey.shortcutKeyCode)
        defaults.set(modifiers, forKey: AppStorageKey.shortcutModifiers)
        defaults.set(kVK_F19, forKey: AppStorageKey.capturePauseShortcutKeyCode)
        defaults.set(modifiers, forKey: AppStorageKey.capturePauseShortcutModifiers)
        defaults.set(kVK_Escape, forKey: AppStorageKey.overlayDismissKeyCode)
        defaults.set(0, forKey: AppStorageKey.overlayDismissModifiers)

        // Prove the synthetic combinations are available before the controller owns them.
        XCTAssertEqual(probeRegistration(kVK_F18, modifiers: modifiers), noErr)
        XCTAssertEqual(probeRegistration(kVK_F19, modifiers: modifiers), noErr)
        let controller = HotKeyController(overlayHandler: {}, capturePauseHandler: {}, logger: { _ in })
        var registrations = 0
        let context = SettingsContext(onShortcutChanged: {
            registrations += 1
            controller.register(configuration: HotKeyConfiguration(
                overlayKeyCode: defaults.integer(forKey: AppStorageKey.shortcutKeyCode),
                overlayModifiers: defaults.integer(forKey: AppStorageKey.shortcutModifiers),
                capturePauseKeyCode: defaults.integer(forKey: AppStorageKey.capturePauseShortcutKeyCode),
                capturePauseModifiers: defaults.integer(forKey: AppStorageKey.capturePauseShortcutModifiers),
                overlayDismissKeyCode: defaults.integer(forKey: AppStorageKey.overlayDismissKeyCode),
                overlayDismissModifiers: defaults.integer(forKey: AppStorageKey.overlayDismissModifiers)
            ))
        }, onShortcutRecordingChanged: { controller.setSuspended($0) })
        context.notifyShortcutChanged()
        XCTAssertEqual(registrations, 1)
        XCTAssertEqual(probeRegistration(kVK_F18, modifiers: modifiers), OSStatus(eventHotKeyExistsErr))
        XCTAssertEqual(probeRegistration(kVK_F19, modifiers: modifiers), OSStatus(eventHotKeyExistsErr))

        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 660, height: 520),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Synthetic shortcut validation"
        let host = NSHostingView(rootView: SettingsView(context: context, selectedTab: .shortcuts)
            .defaultAppStorage(defaults))
        window.contentView = host
        defer {
            window.makeFirstResponder(nil)
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        window.makeKeyAndOrderFront(nil)
        try await waitUntil { self.recorders(in: host).count == 3 }
        let recorder = try XCTUnwrap(recorders(in: host).first)
        XCTAssertFalse(recorder.allowsEscapeShortcut)
        XCTAssertTrue(recorder.accessibilityPerformPress())
        try await waitUntil { recorder.accessibilityValue() as? String == "Press shortcut" }
        XCTAssertTrue(window.firstResponder === recorder)

        // Both real registrations must be released synchronously at recording start.
        XCTAssertEqual(probeRegistration(kVK_F18, modifiers: modifiers), noErr,
                       "Open rewind must be released while Settings records a shortcut")
        XCTAssertEqual(probeRegistration(kVK_F19, modifiers: modifiers), noErr,
                       "Pause recording must be released while Settings records a shortcut")
        let beforeReregistration = registrations
        context.notifyShortcutChanged()
        XCTAssertEqual(registrations, beforeReregistration + 1)
        XCTAssertEqual(recorder.accessibilityValue() as? String, "Press shortcut")
        XCTAssertEqual(probeRegistration(kVK_F18, modifiers: modifiers), noErr,
                       "Re-registering configured values must not end suspension")
        XCTAssertEqual(probeRegistration(kVK_F19, modifiers: modifiers), noErr)

        recorder.keyDown(with: try keyEvent(kVK_Escape))
        try await waitUntil { recorder.accessibilityValue() as? String != "Press shortcut" }
        XCTAssertEqual(defaults.integer(forKey: AppStorageKey.shortcutKeyCode), kVK_F18)
        XCTAssertEqual(defaults.integer(forKey: AppStorageKey.capturePauseShortcutKeyCode), kVK_F19)
        XCTAssertEqual(probeRegistration(kVK_F18, modifiers: modifiers), OSStatus(eventHotKeyExistsErr))
        XCTAssertEqual(probeRegistration(kVK_F19, modifiers: modifiers), OSStatus(eventHotKeyExistsErr))

        // A new captured chord is persisted before suspension ends, not on delayed onChange.
        XCTAssertEqual(probeRegistration(kVK_F20, modifiers: modifiers), noErr)
        recorder.accessibilityPerformPress()
        recorder.keyDown(with: try keyEvent(kVK_F20, modifiers: [.command, .option, .control, .shift]))
        XCTAssertEqual(defaults.integer(forKey: AppStorageKey.shortcutKeyCode), kVK_F20)
        XCTAssertEqual(probeRegistration(kVK_F18, modifiers: modifiers), noErr)
        XCTAssertEqual(probeRegistration(kVK_F20, modifiers: modifiers), OSStatus(eventHotKeyExistsErr))
        XCTAssertEqual(probeRegistration(kVK_F19, modifiers: modifiers), OSStatus(eventHotKeyExistsErr))

        // Preference changes while suspended must update the configuration without constructing HotKey.
        recorder.accessibilityPerformPress()
        defaults.set(kVK_F18, forKey: AppStorageKey.shortcutKeyCode)
        context.notifyShortcutChanged()
        XCTAssertEqual(probeRegistration(kVK_F18, modifiers: modifiers), noErr)
        XCTAssertEqual(probeRegistration(kVK_F20, modifiers: modifiers), noErr)
        XCTAssertEqual(probeRegistration(kVK_F19, modifiers: modifiers), noErr)
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(probeRegistration(kVK_F18, modifiers: modifiers), OSStatus(eventHotKeyExistsErr))
        XCTAssertEqual(probeRegistration(kVK_F20, modifiers: modifiers), noErr)
        XCTAssertEqual(probeRegistration(kVK_F19, modifiers: modifiers), OSStatus(eventHotKeyExistsErr))

        recorder.accessibilityPerformPress()
        XCTAssertEqual(probeRegistration(kVK_F18, modifiers: modifiers), noErr)
        window.resignKey()
        XCTAssertNotEqual(recorder.accessibilityValue() as? String, "Press shortcut")
        XCTAssertEqual(probeRegistration(kVK_F18, modifiers: modifiers), OSStatus(eventHotKeyExistsErr))
        XCTAssertEqual(probeRegistration(kVK_F19, modifiers: modifiers), OSStatus(eventHotKeyExistsErr))

        window.makeKeyAndOrderFront(nil)
        recorder.accessibilityPerformPress()
        XCTAssertEqual(probeRegistration(kVK_F18, modifiers: modifiers), noErr)
        XCTAssertEqual(probeRegistration(kVK_F19, modifiers: modifiers), noErr)
        window.contentView = nil
        XCTAssertNotEqual(recorder.accessibilityValue() as? String, "Press shortcut")
        XCTAssertEqual(probeRegistration(kVK_F18, modifiers: modifiers), OSStatus(eventHotKeyExistsErr))
        XCTAssertEqual(probeRegistration(kVK_F19, modifiers: modifiers), OSStatus(eventHotKeyExistsErr))
    }

    /// Exclusive probes detect an existing owner even when Carbon permits shared registrations.
    /// Every successful probe is immediately released; no synthetic hotkey events are sent.
    private func probeRegistration(_ keyCode: Int, modifiers: Int) -> OSStatus {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), HotKeyController.carbonModifiers(for: modifiers),
            EventHotKeyID(signature: 0x4A4E5233, id: UInt32(keyCode)), GetApplicationEventTarget(),
            UInt32(kEventHotKeyExclusive), &reference)
        if let reference { UnregisterEventHotKey(reference) }
        return status
    }

    private func recorders(in root: NSView) -> [RecorderNSView] {
        if let recorder = root as? RecorderNSView { return [recorder] }
        return root.subviews.flatMap { recorders(in: $0) }
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out waiting for hosted Settings recorder")
    }

    func testSpaceStartsRecordingAndCaptureDropsCapsLock() throws {
        let recorder = RecorderNSView(frame: .zero)
        let delegate = RecorderDelegateProbe()
        recorder.delegate = delegate

        recorder.keyDown(with: try keyEvent(kVK_Space))
        XCTAssertEqual(delegate.starts, 1)
        recorder.keyDown(with: try keyEvent(kVK_ANSI_K, modifiers: [.command, .capsLock]))
        XCTAssertEqual(delegate.keyCode, Int(kVK_ANSI_K))
        XCTAssertEqual(delegate.modifiers, Int(NSEvent.ModifierFlags.command.rawValue))
    }

    func testAccessibilityPressStartsRecordingAndEscapeCancels() throws {
        let recorder = RecorderNSView(frame: .zero)
        let delegate = RecorderDelegateProbe()
        recorder.delegate = delegate

        XCTAssertTrue(recorder.accessibilityPerformPress())
        XCTAssertEqual(recorder.accessibilityRole(), .button)
        XCTAssertEqual(recorder.accessibilityLabel(), "Record keyboard shortcut")
        XCTAssertEqual(delegate.starts, 1)
        recorder.keyDown(with: try keyEvent(kVK_Escape))
        XCTAssertEqual(delegate.ends, 1)
        XCTAssertNil(delegate.keyCode)
    }

    func testDisplayUpdatesDoNotChangeRecordingAndCancellationEndsOnce() {
        let recorder = RecorderNSView(frame: .zero)
        let delegate = RecorderDelegateProbe()
        recorder.delegate = delegate
        recorder.accessibilityPerformPress()
        recorder.updateDisplay(keyCode: kVK_F18, modifiers: 0)
        XCTAssertEqual(recorder.accessibilityValue() as? String, "Press shortcut")
        recorder.cancelRecording()
        recorder.cancelRecording()
        recorder.updateDisplay(keyCode: kVK_F19, modifiers: 0)
        XCTAssertNotEqual(recorder.accessibilityValue() as? String, "Press shortcut")
        XCTAssertEqual(delegate.starts, 1)
        XCTAssertEqual(delegate.ends, 1)
    }

    private func keyEvent(_ keyCode: Int, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false,
            keyCode: UInt16(keyCode)
        ))
    }
}

private final class RecorderDelegateProbe: RecorderNSViewDelegate {
    var starts = 0
    var ends = 0
    var keyCode: Int?
    var modifiers: Int?

    func recorderDidStartRecording() { starts += 1 }
    func recorderDidEndRecording() { ends += 1 }
    func recorderDidCaptureShortcut(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}
