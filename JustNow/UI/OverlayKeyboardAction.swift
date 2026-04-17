//
//  OverlayKeyboardAction.swift
//  JustNow
//

import AppKit
import Carbon.HIToolbox

struct OverlayKeyboardState: Equatable {
    let isSearchAvailable: Bool
    let isSearching: Bool
    let hasSearchQuery: Bool
    let isTextGrabActive: Bool
}

enum OverlayKeyboardAction: Equatable {
    case passthrough
    case consume
    case dismissOverlay
    case cancelTextGrab
    case clearSearch
    case toggleSearch
    case submitSearch
    case moveLeft
    case jumpLeft
    case goToStart
    case moveRight
    case jumpRight
    case goToEnd
    case cycleDisplayForward
    case cycleDisplayBackward
}

func resolveOverlayKeyboardAction(
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags,
    dismissShortcutKeyCode: Int,
    dismissShortcutModifiers: Int,
    state: OverlayKeyboardState
) -> OverlayKeyboardAction {
    let pressedModifiers = modifiers.intersection(.deviceIndependentFlagsMask)
    let dismissModifiers = NSEvent.ModifierFlags(rawValue: UInt(dismissShortcutModifiers))
        .intersection(.deviceIndependentFlagsMask)
    let matchesDismissShortcut = Int(keyCode) == dismissShortcutKeyCode && pressedModifiers == dismissModifiers

    if matchesDismissShortcut && keyCode != UInt16(kVK_Escape) {
        return .dismissOverlay
    }

    switch keyCode {
    case UInt16(kVK_Escape):
        if state.isTextGrabActive {
            return .cancelTextGrab
        }
        if state.isSearchAvailable && state.isSearching {
            return .clearSearch
        }
        return .dismissOverlay

    case UInt16(kVK_ANSI_Slash):
        guard state.isSearchAvailable else { return .consume }
        return state.isSearching ? .passthrough : .toggleSearch

    case UInt16(kVK_Return):
        if state.isSearchAvailable && state.isSearching && state.hasSearchQuery {
            return .submitSearch
        }
        return .passthrough

    case UInt16(kVK_LeftArrow):
        if pressedModifiers.contains(.command) {
            return .goToStart
        }
        if pressedModifiers.contains(.option) {
            return .jumpLeft
        }
        return .moveLeft

    case UInt16(kVK_RightArrow):
        if pressedModifiers.contains(.command) {
            return .goToEnd
        }
        if pressedModifiers.contains(.option) {
            return .jumpRight
        }
        return .moveRight

    case UInt16(kVK_Tab):
        if state.isSearchAvailable && state.isSearching {
            return .passthrough
        }
        return pressedModifiers.contains(.shift) ? .cycleDisplayBackward : .cycleDisplayForward

    default:
        return matchesDismissShortcut ? .dismissOverlay : .passthrough
    }
}
