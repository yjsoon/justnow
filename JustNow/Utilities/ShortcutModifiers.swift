import AppKit

extension NSEvent.ModifierFlags {
    /// Only these flags form a shortcut. Caps Lock, Fn, and numeric-pad
    /// state must not change matching or conflicts for persisted shortcuts.
    static let shortcutModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
}
