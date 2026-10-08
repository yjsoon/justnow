import XCTest
@testable import JustNow

@MainActor
final class SettingsContextTests: XCTestCase {
    func testRecordingTracksDistinctRecordersAndRefreshesBeforeResume() {
        var events: [String] = []
        let context = SettingsContext(
            onShortcutChanged: { events.append("refresh") },
            onShortcutRecordingChanged: { events.append($0 ? "suspend" : "resume") }
        )
        let first = UUID()
        let second = UUID()
        context.notifyShortcutRecordingChanged(recorderID: first, isRecording: true)
        context.notifyShortcutRecordingChanged(recorderID: first, isRecording: true)
        context.notifyShortcutRecordingChanged(recorderID: second, isRecording: true)
        context.notifyShortcutRecordingChanged(recorderID: first, isRecording: false)
        context.notifyShortcutRecordingChanged(recorderID: first, isRecording: false)
        context.notifyShortcutRecordingChanged(recorderID: UUID(), isRecording: false)
        XCTAssertEqual(events, ["suspend"])
        context.notifyShortcutRecordingChanged(recorderID: second, isRecording: false)
        context.notifyShortcutRecordingChanged(recorderID: second, isRecording: false)
        XCTAssertEqual(events, ["suspend", "refresh", "resume"])
    }

    func testRelaunchCallsInjectedAction() {
        var relaunchCount = 0
        let context = SettingsContext(onRelaunch: {
            relaunchCount += 1
        })

        context.relaunch()

        XCTAssertEqual(relaunchCount, 1)
    }
}
