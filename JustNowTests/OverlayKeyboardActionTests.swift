import AppKit
import Carbon.HIToolbox
import XCTest
@testable import JustNow

final class OverlayKeyboardActionTests: XCTestCase {
    func testReturnBelongsToTheNativeResponderWhileSearchIsOpen() {
        for editing in [true, false] {
            let state = OverlayKeyboardState(
                isSearchAvailable: true, isSearching: true,
                isTextGrabActive: false, isEditingText: editing
            )
            XCTAssertEqual(resolveOverlayKeyboardAction(
                keyCode: UInt16(kVK_Return), modifiers: [],
                dismissShortcutKeyCode: kVK_Escape, dismissShortcutModifiers: 0,
                state: state
            ), .passthrough, "The field owns submission/composition; focused buttons own activation")
        }
    }

    func testConfiguredArrowDismissalStillWorksWhileEditing() {
        let state = OverlayKeyboardState(
            isSearchAvailable: true, isSearching: true,
            isTextGrabActive: false, isEditingText: true
        )
        for (modifiers, expected): (NSEvent.ModifierFlags, OverlayKeyboardAction) in [
            (.command, .dismissOverlay), (.option, .passthrough), ([], .passthrough)
        ] {
            XCTAssertEqual(resolveOverlayKeyboardAction(
                keyCode: UInt16(kVK_LeftArrow), modifiers: modifiers,
                dismissShortcutKeyCode: kVK_LeftArrow,
                dismissShortcutModifiers: Int(NSEvent.ModifierFlags.command.rawValue),
                state: state
            ), expected)
        }
    }

    func testTextEditingKeepsNavigationKeysButUnfocusedSearchStillNavigatesFrames() {
        let editing = OverlayKeyboardState(
            isSearchAvailable: true, isSearching: true,
            isTextGrabActive: false, isEditingText: true
        )
        var unfocused = editing
        unfocused.isEditingText = false
        let modifiers: [NSEvent.ModifierFlags] = [[], .shift, .option, [.option, .shift], .command, [.command, .shift]]
        for key in [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown] {
            for flags in modifiers {
                XCTAssertEqual(resolveOverlayKeyboardAction(
                    keyCode: UInt16(key), modifiers: flags,
                    dismissShortcutKeyCode: kVK_Escape, dismissShortcutModifiers: 0,
                    state: editing
                ), .passthrough)
            }
        }
        XCTAssertEqual(resolveOverlayKeyboardAction(
            keyCode: UInt16(kVK_LeftArrow), modifiers: .option,
            dismissShortcutKeyCode: kVK_Escape, dismissShortcutModifiers: 0,
            state: unfocused
        ), .jumpLeft)
        XCTAssertEqual(resolveOverlayKeyboardAction(
            keyCode: UInt16(kVK_Escape), modifiers: [],
            dismissShortcutKeyCode: kVK_Escape, dismissShortcutModifiers: 0,
            state: editing
        ), .clearSearch)
    }

    func testDismissShortcutIgnoresStateFlagsInBothSavedAndPressedModifiers() {
        for (pressed, saved) in [
            (NSEvent.ModifierFlags([.command, .capsLock]), NSEvent.ModifierFlags.command),
            (.command, [.command, .capsLock, .numericPad, .function])
        ] {
            XCTAssertEqual(resolveOverlayKeyboardAction(
                keyCode: UInt16(kVK_ANSI_J),
                modifiers: pressed,
                dismissShortcutKeyCode: Int(kVK_ANSI_J),
                dismissShortcutModifiers: Int(saved.rawValue),
                state: .init(isSearchAvailable: true, isSearching: false, isTextGrabActive: false)
            ), .dismissOverlay)
        }
    }

    func testDismissShortcutDismissesWhenNotEscape() {
        let action = resolveOverlayKeyboardAction(
            keyCode: UInt16(kVK_ANSI_J),
            modifiers: [.command, .option],
            dismissShortcutKeyCode: Int(kVK_ANSI_J),
            dismissShortcutModifiers: Int((NSEvent.ModifierFlags.command.union(.option)).rawValue),
            state: .init(isSearchAvailable: true, isSearching: false, isTextGrabActive: false)
        )

        XCTAssertEqual(action, .dismissOverlay)
    }

    func testEscapeCancelsActiveTextGrabBeforeAnythingElse() {
        let action = resolveOverlayKeyboardAction(
            keyCode: UInt16(kVK_Escape),
            modifiers: [],
            dismissShortcutKeyCode: Int(kVK_Escape),
            dismissShortcutModifiers: 0,
            state: .init(isSearchAvailable: true, isSearching: true, isTextGrabActive: true)
        )

        XCTAssertEqual(action, .cancelTextGrab)
    }

    func testSlashFocusesSearchWhenAvailableAndClosed() {
        let action = resolveOverlayKeyboardAction(
            keyCode: UInt16(kVK_ANSI_Slash),
            modifiers: [],
            dismissShortcutKeyCode: Int(kVK_Escape),
            dismissShortcutModifiers: 0,
            state: .init(isSearchAvailable: true, isSearching: false, isTextGrabActive: false)
        )

        XCTAssertEqual(action, .focusSearch)
    }

    func testSlashPassesThroughWhileTypingIntoSearch() {
        let action = resolveOverlayKeyboardAction(
            keyCode: UInt16(kVK_ANSI_Slash),
            modifiers: [],
            dismissShortcutKeyCode: Int(kVK_Escape),
            dismissShortcutModifiers: 0,
            state: .init(isSearchAvailable: true, isSearching: true, isTextGrabActive: false, isEditingText: true)
        )

        XCTAssertEqual(action, .passthrough)
    }

    func testSearchFocusShortcutsPreserveNativeEditingAndTabTraversal() {
        for editing in [false, true] {
            let state = OverlayKeyboardState(
                isSearchAvailable: true, isSearching: true,
                isTextGrabActive: false, isEditingText: editing
            )
            for (key, flags, expected): (Int, NSEvent.ModifierFlags, OverlayKeyboardAction) in [
                (kVK_ANSI_Slash, [], editing ? .passthrough : .focusSearch),
                (kVK_ANSI_Slash, .shift, .passthrough),
                (kVK_ANSI_F, .command, .focusSearch),
                (kVK_ANSI_F, .control, .passthrough),
                (kVK_Tab, [], .passthrough),
                (kVK_Tab, .shift, .passthrough)
            ] {
                XCTAssertEqual(resolveOverlayKeyboardAction(
                    keyCode: UInt16(key), modifiers: flags,
                    dismissShortcutKeyCode: kVK_Escape, dismissShortcutModifiers: 0,
                    state: state
                ), expected)
            }
        }
    }

    func testCommandSResolvesToSaveScreenshot() {
        let action = resolveOverlayKeyboardAction(
            keyCode: UInt16(kVK_ANSI_S),
            modifiers: [.command],
            dismissShortcutKeyCode: Int(kVK_Escape),
            dismissShortcutModifiers: 0,
            state: .init(isSearchAvailable: true, isSearching: false, isTextGrabActive: false)
        )

        XCTAssertEqual(action, .saveScreenshot)
    }

    func testPlainSPassesThroughWithoutCommand() {
        let action = resolveOverlayKeyboardAction(
            keyCode: UInt16(kVK_ANSI_S),
            modifiers: [],
            dismissShortcutKeyCode: Int(kVK_Escape),
            dismissShortcutModifiers: 0,
            state: .init(isSearchAvailable: true, isSearching: false, isTextGrabActive: false)
        )

        XCTAssertEqual(action, .passthrough)
    }

    func testCommandCommaResolvesToOpenSettings() {
        let action = resolveOverlayKeyboardAction(
            keyCode: UInt16(kVK_ANSI_Comma),
            modifiers: [.command],
            dismissShortcutKeyCode: Int(kVK_Escape),
            dismissShortcutModifiers: 0,
            state: .init(isSearchAvailable: true, isSearching: false, isTextGrabActive: false)
        )

        XCTAssertEqual(action, .openSettings)
    }

    func testPlainCommaPassesThroughWithoutCommand() {
        let action = resolveOverlayKeyboardAction(
            keyCode: UInt16(kVK_ANSI_Comma),
            modifiers: [],
            dismissShortcutKeyCode: Int(kVK_Escape),
            dismissShortcutModifiers: 0,
            state: .init(isSearchAvailable: true, isSearching: false, isTextGrabActive: false)
        )

        XCTAssertEqual(action, .passthrough)
    }

    func testArrowModifiersMapToJumpAndBoundaryActions() {
        let dismissModifiers = Int(NSEvent.ModifierFlags.command.rawValue)

        XCTAssertEqual(
            resolveOverlayKeyboardAction(
                keyCode: UInt16(kVK_LeftArrow),
                modifiers: [.option],
                dismissShortcutKeyCode: Int(kVK_Escape),
                dismissShortcutModifiers: dismissModifiers,
                state: .init(isSearchAvailable: true, isSearching: false, isTextGrabActive: false)
            ),
            .jumpLeft
        )

        XCTAssertEqual(
            resolveOverlayKeyboardAction(
                keyCode: UInt16(kVK_RightArrow),
                modifiers: [.command],
                dismissShortcutKeyCode: Int(kVK_Escape),
                dismissShortcutModifiers: dismissModifiers,
                state: .init(isSearchAvailable: true, isSearching: false, isTextGrabActive: false)
            ),
            .goToEnd
        )
    }

    func testPageAndBoundaryKeysMapToElapsedNavigation() {
        let state = OverlayKeyboardState(
            isSearchAvailable: true,
            isSearching: false,
            isTextGrabActive: false
        )

        func action(for keyCode: Int) -> OverlayKeyboardAction {
            resolveOverlayKeyboardAction(
                keyCode: UInt16(keyCode),
                modifiers: [],
                dismissShortcutKeyCode: Int(kVK_Escape),
                dismissShortcutModifiers: 0,
                state: state
            )
        }

        XCTAssertEqual(action(for: kVK_PageUp), .jumpLeft)
        XCTAssertEqual(action(for: kVK_PageDown), .jumpRight)
        XCTAssertEqual(action(for: kVK_Home), .goToStart)
        XCTAssertEqual(action(for: kVK_End), .goToEnd)
    }
}
