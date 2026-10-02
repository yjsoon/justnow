import AppKit
import Carbon.HIToolbox
import XCTest
@testable import JustNow

@MainActor
final class KeyboardShortcutRecorderTests: XCTestCase {
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
