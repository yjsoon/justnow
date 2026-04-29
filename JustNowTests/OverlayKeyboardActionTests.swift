import AppKit
import Carbon.HIToolbox
import XCTest
@testable import JustNow

final class OverlayKeyboardActionTests: XCTestCase {
    func testDismissShortcutDismissesWhenNotEscape() {
        let action = resolveOverlayKeyboardAction(
            keyCode: UInt16(kVK_ANSI_J),
            modifiers: [.command, .option],
            dismissShortcutKeyCode: Int(kVK_ANSI_J),
            dismissShortcutModifiers: Int((NSEvent.ModifierFlags.command.union(.option)).rawValue),
            state: .init(isSearchAvailable: true, isSearching: false, hasSearchQuery: false, isTextGrabActive: false)
        )

        XCTAssertEqual(action, .dismissOverlay)
    }

    func testEscapeCancelsActiveTextGrabBeforeAnythingElse() {
        let action = resolveOverlayKeyboardAction(
            keyCode: UInt16(kVK_Escape),
            modifiers: [],
            dismissShortcutKeyCode: Int(kVK_Escape),
            dismissShortcutModifiers: 0,
            state: .init(isSearchAvailable: true, isSearching: true, hasSearchQuery: true, isTextGrabActive: true)
        )

        XCTAssertEqual(action, .cancelTextGrab)
    }

    func testSlashTogglesSearchWhenAvailableAndClosed() {
        let action = resolveOverlayKeyboardAction(
            keyCode: UInt16(kVK_ANSI_Slash),
            modifiers: [],
            dismissShortcutKeyCode: Int(kVK_Escape),
            dismissShortcutModifiers: 0,
            state: .init(isSearchAvailable: true, isSearching: false, hasSearchQuery: false, isTextGrabActive: false)
        )

        XCTAssertEqual(action, .toggleSearch)
    }

    func testSlashPassesThroughWhileTypingIntoSearch() {
        let action = resolveOverlayKeyboardAction(
            keyCode: UInt16(kVK_ANSI_Slash),
            modifiers: [],
            dismissShortcutKeyCode: Int(kVK_Escape),
            dismissShortcutModifiers: 0,
            state: .init(isSearchAvailable: true, isSearching: true, hasSearchQuery: true, isTextGrabActive: false)
        )

        XCTAssertEqual(action, .passthrough)
    }

    func testCommandSResolvesToSaveScreenshot() {
        let action = resolveOverlayKeyboardAction(
            keyCode: UInt16(kVK_ANSI_S),
            modifiers: [.command],
            dismissShortcutKeyCode: Int(kVK_Escape),
            dismissShortcutModifiers: 0,
            state: .init(isSearchAvailable: true, isSearching: false, hasSearchQuery: false, isTextGrabActive: false)
        )

        XCTAssertEqual(action, .saveScreenshot)
    }

    func testPlainSPassesThroughWithoutCommand() {
        let action = resolveOverlayKeyboardAction(
            keyCode: UInt16(kVK_ANSI_S),
            modifiers: [],
            dismissShortcutKeyCode: Int(kVK_Escape),
            dismissShortcutModifiers: 0,
            state: .init(isSearchAvailable: true, isSearching: false, hasSearchQuery: false, isTextGrabActive: false)
        )

        XCTAssertEqual(action, .passthrough)
    }

    func testCommandCommaResolvesToOpenSettings() {
        let action = resolveOverlayKeyboardAction(
            keyCode: UInt16(kVK_ANSI_Comma),
            modifiers: [.command],
            dismissShortcutKeyCode: Int(kVK_Escape),
            dismissShortcutModifiers: 0,
            state: .init(isSearchAvailable: true, isSearching: false, hasSearchQuery: false, isTextGrabActive: false)
        )

        XCTAssertEqual(action, .openSettings)
    }

    func testPlainCommaPassesThroughWithoutCommand() {
        let action = resolveOverlayKeyboardAction(
            keyCode: UInt16(kVK_ANSI_Comma),
            modifiers: [],
            dismissShortcutKeyCode: Int(kVK_Escape),
            dismissShortcutModifiers: 0,
            state: .init(isSearchAvailable: true, isSearching: false, hasSearchQuery: false, isTextGrabActive: false)
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
                state: .init(isSearchAvailable: true, isSearching: false, hasSearchQuery: false, isTextGrabActive: false)
            ),
            .jumpLeft
        )

        XCTAssertEqual(
            resolveOverlayKeyboardAction(
                keyCode: UInt16(kVK_RightArrow),
                modifiers: [.command],
                dismissShortcutKeyCode: Int(kVK_Escape),
                dismissShortcutModifiers: dismissModifiers,
                state: .init(isSearchAvailable: true, isSearching: false, hasSearchQuery: false, isTextGrabActive: false)
            ),
            .goToEnd
        )
    }
}
