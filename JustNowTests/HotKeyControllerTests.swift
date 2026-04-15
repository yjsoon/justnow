import AppKit
import Carbon.HIToolbox
import XCTest
@testable import JustNow

final class HotKeyControllerTests: XCTestCase {
    func testRegistrationPlanSkipsPauseHotKeyWhenItMatchesOverlayShortcut() {
        let modifiers = Int(UInt(NSEvent.ModifierFlags.command.rawValue))
        let configuration = HotKeyConfiguration(
            overlayKeyCode: 38,
            overlayModifiers: modifiers,
            capturePauseKeyCode: 38,
            capturePauseModifiers: modifiers,
            overlayDismissKeyCode: 53,
            overlayDismissModifiers: 0
        )

        XCTAssertEqual(
            HotKeyController.registrationPlan(for: configuration),
            HotKeyRegistrationPlan(
                shouldRegisterPauseHotKey: false,
                skipMessage: "Skipping pause hotkey registration because it matches the open rewind shortcut"
            )
        )
    }

    func testRegistrationPlanSkipsPauseHotKeyWhenItMatchesOverlayDismissShortcut() {
        let modifiers = Int(UInt(NSEvent.ModifierFlags.command.rawValue))
        let configuration = HotKeyConfiguration(
            overlayKeyCode: 38,
            overlayModifiers: modifiers,
            capturePauseKeyCode: 53,
            capturePauseModifiers: modifiers,
            overlayDismissKeyCode: 53,
            overlayDismissModifiers: modifiers
        )

        XCTAssertEqual(
            HotKeyController.registrationPlan(for: configuration),
            HotKeyRegistrationPlan(
                shouldRegisterPauseHotKey: false,
                skipMessage: "Skipping pause hotkey registration because it matches the close rewind shortcut"
            )
        )
    }

    func testRegistrationPlanAllowsDistinctPauseHotKey() {
        let configuration = HotKeyConfiguration(
            overlayKeyCode: 38,
            overlayModifiers: Int(UInt(NSEvent.ModifierFlags.command.rawValue)),
            capturePauseKeyCode: 35,
            capturePauseModifiers: Int(UInt(NSEvent.ModifierFlags.option.rawValue)),
            overlayDismissKeyCode: 53,
            overlayDismissModifiers: 0
        )

        XCTAssertEqual(
            HotKeyController.registrationPlan(for: configuration),
            HotKeyRegistrationPlan(
                shouldRegisterPauseHotKey: true,
                skipMessage: nil
            )
        )
    }

    func testCarbonModifiersMapsCommandOptionControlAndShift() {
        let modifiers = NSEvent.ModifierFlags([.command, .option, .control, .shift])

        XCTAssertEqual(
            HotKeyController.carbonModifiers(for: Int(UInt(modifiers.rawValue))),
            UInt32(cmdKey | optionKey | controlKey | shiftKey)
        )
    }
}
