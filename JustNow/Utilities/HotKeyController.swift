import AppKit
import Carbon.HIToolbox
import HotKey

struct HotKeyConfiguration {
    let overlayKeyCode: Int
    let overlayModifiers: Int
    let capturePauseKeyCode: Int
    let capturePauseModifiers: Int
    let overlayDismissKeyCode: Int
    let overlayDismissModifiers: Int
}

struct HotKeyRegistrationPlan: Equatable {
    let shouldRegisterPauseHotKey: Bool
    let skipMessage: String?
}

@MainActor
final class HotKeyController {
    private var overlayHotKey: HotKey?
    private var capturePauseHotKey: HotKey?

    private let overlayHandler: () -> Void
    private let capturePauseHandler: () -> Void
    private let logger: (String) -> Void

    init(
        overlayHandler: @escaping () -> Void,
        capturePauseHandler: @escaping () -> Void,
        logger: @escaping (String) -> Void = { print($0) }
    ) {
        self.overlayHandler = overlayHandler
        self.capturePauseHandler = capturePauseHandler
        self.logger = logger
    }

    func register(configuration: HotKeyConfiguration) {
        overlayHotKey = nil
        capturePauseHotKey = nil

        overlayHotKey = makeHotKey(
            keyCode: configuration.overlayKeyCode,
            modifiers: configuration.overlayModifiers,
            handler: overlayHandler
        )

        let plan = Self.registrationPlan(for: configuration)
        guard plan.shouldRegisterPauseHotKey else {
            if let skipMessage = plan.skipMessage {
                logger(skipMessage)
            }
            return
        }

        capturePauseHotKey = makeHotKey(
            keyCode: configuration.capturePauseKeyCode,
            modifiers: configuration.capturePauseModifiers,
            handler: capturePauseHandler
        )
    }

    static func registrationPlan(for configuration: HotKeyConfiguration) -> HotKeyRegistrationPlan {
        guard configuration.capturePauseKeyCode != -1 else {
            return HotKeyRegistrationPlan(
                shouldRegisterPauseHotKey: false,
                skipMessage: nil
            )
        }

        if conflicts(
            configuration.capturePauseKeyCode,
            configuration.capturePauseModifiers,
            configuration.overlayKeyCode,
            configuration.overlayModifiers
        ) {
            return HotKeyRegistrationPlan(
                shouldRegisterPauseHotKey: false,
                skipMessage: "Skipping pause hotkey registration because it matches the open rewind shortcut"
            )
        }

        if conflicts(
            configuration.capturePauseKeyCode,
            configuration.capturePauseModifiers,
            configuration.overlayDismissKeyCode,
            configuration.overlayDismissModifiers
        ) {
            return HotKeyRegistrationPlan(
                shouldRegisterPauseHotKey: false,
                skipMessage: "Skipping pause hotkey registration because it matches the close rewind shortcut"
            )
        }

        return HotKeyRegistrationPlan(
            shouldRegisterPauseHotKey: true,
            skipMessage: nil
        )
    }

    static func carbonModifiers(for modifiers: Int) -> UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        var carbonModifiers: UInt32 = 0
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        return carbonModifiers
    }

    static func conflicts(_ lhsKeyCode: Int, _ lhsModifiers: Int, _ rhsKeyCode: Int, _ rhsModifiers: Int) -> Bool {
        lhsKeyCode != -1
            && rhsKeyCode != -1
            && lhsKeyCode == rhsKeyCode
            && lhsModifiers == rhsModifiers
    }

    private func makeHotKey(
        keyCode: Int,
        modifiers: Int,
        handler: @escaping () -> Void
    ) -> HotKey? {
        guard keyCode != -1 else { return nil }

        let hotKey = HotKey(
            carbonKeyCode: UInt32(keyCode),
            carbonModifiers: Self.carbonModifiers(for: modifiers)
        )
        hotKey.keyDownHandler = handler
        return hotKey
    }
}
