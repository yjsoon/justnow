//
//  KeyboardShortcutRecorder.swift
//  JustNow
//

import SwiftUI
import AppKit
import Carbon.HIToolbox

struct KeyboardShortcutRecorder: View {
    @Binding var keyCode: Int
    @Binding var modifiers: Int

    @State private var isRecording = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            RecorderField(
                keyCode: $keyCode,
                modifiers: $modifiers,
                isRecording: $isRecording
            )
            .frame(minWidth: 120, maxWidth: 200)
            .frame(height: 24)
            .background(isRecording ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isRecording ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
            )

            if keyCode != -1 {
                Button {
                    keyCode = -1
                    modifiers = 0
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
            }
        }
    }
}

// MARK: - Recorder Field (NSViewRepresentable)

struct RecorderField: NSViewRepresentable {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    @Binding var isRecording: Bool

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: RecorderNSView, context: Context) {
        nsView.updateDisplay(keyCode: keyCode, modifiers: modifiers, isRecording: isRecording)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, RecorderNSViewDelegate {
        var parent: RecorderField

        init(_ parent: RecorderField) {
            self.parent = parent
        }

        func recorderDidStartRecording() {
            parent.isRecording = true
        }

        func recorderDidEndRecording() {
            parent.isRecording = false
        }

        func recorderDidCaptureShortcut(keyCode: Int, modifiers: Int) {
            parent.keyCode = keyCode
            parent.modifiers = modifiers
            parent.isRecording = false
        }
    }
}

// MARK: - RecorderNSView

protocol RecorderNSViewDelegate: AnyObject {
    func recorderDidStartRecording()
    func recorderDidEndRecording()
    func recorderDidCaptureShortcut(keyCode: Int, modifiers: Int)
}

class RecorderNSView: NSView {
    weak var delegate: RecorderNSViewDelegate?

    private var isRecording = false
    private var currentKeyCode: Int = -1
    private var currentModifiers: Int = 0

    private let textField: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.alignment = .center
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        return field
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        addSubview(textField)
        textField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textField.centerXAnchor.constraint(equalTo: centerXAnchor),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            textField.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        ])

        updateDisplayText()
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if !isRecording {
            startRecording()
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        // Escape cancels recording
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Require at least one modifier (cmd, opt, ctrl, or shift)
        guard mods.contains(.command) || mods.contains(.option) || mods.contains(.control) || mods.contains(.shift) else {
            return
        }

        // Don't accept modifier-only presses
        let modifierOnlyKeys: Set<UInt16> = [
            UInt16(kVK_Command), UInt16(kVK_RightCommand),
            UInt16(kVK_Option), UInt16(kVK_RightOption),
            UInt16(kVK_Control), UInt16(kVK_RightControl),
            UInt16(kVK_Shift), UInt16(kVK_RightShift)
        ]

        if modifierOnlyKeys.contains(event.keyCode) {
            return
        }

        // Valid shortcut captured
        currentKeyCode = Int(event.keyCode)
        currentModifiers = Int(mods.rawValue)
        delegate?.recorderDidCaptureShortcut(keyCode: currentKeyCode, modifiers: currentModifiers)
        stopRecording()
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }

        // Show current modifiers while recording
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        textField.stringValue = modifierSymbols(from: mods) + "..."
        textField.textColor = .labelColor
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            stopRecording()
        }
        return super.resignFirstResponder()
    }

    private func startRecording() {
        isRecording = true
        window?.makeFirstResponder(self)
        textField.stringValue = "Press shortcut..."
        textField.textColor = .labelColor
        delegate?.recorderDidStartRecording()
    }

    private func stopRecording() {
        isRecording = false
        window?.makeFirstResponder(nil)
        updateDisplayText()
        delegate?.recorderDidEndRecording()
    }

    func updateDisplay(keyCode: Int, modifiers: Int, isRecording: Bool) {
        self.currentKeyCode = keyCode
        self.currentModifiers = modifiers
        self.isRecording = isRecording

        if !isRecording {
            updateDisplayText()
        }
    }

    private func updateDisplayText() {
        if currentKeyCode == -1 {
            textField.stringValue = "Click to set"
            textField.textColor = .secondaryLabelColor
        } else {
            let mods = NSEvent.ModifierFlags(rawValue: UInt(currentModifiers))
            textField.stringValue = modifierSymbols(from: mods) + keyString(from: currentKeyCode)
            textField.textColor = .labelColor
        }
    }

    private func modifierSymbols(from flags: NSEvent.ModifierFlags) -> String {
        var symbols = ""
        if flags.contains(.control) { symbols += "⌃" }
        if flags.contains(.option) { symbols += "⌥" }
        if flags.contains(.shift) { symbols += "⇧" }
        if flags.contains(.command) { symbols += "⌘" }
        return symbols
    }

    private func keyString(from keyCode: Int) -> String {
        let specialKeys: [Int: String] = [
            kVK_Return: "↩",
            kVK_Tab: "⇥",
            kVK_Space: "Space",
            kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦",
            kVK_Escape: "⎋",
            kVK_LeftArrow: "←",
            kVK_RightArrow: "→",
            kVK_UpArrow: "↑",
            kVK_DownArrow: "↓",
            kVK_Home: "↖",
            kVK_End: "↘",
            kVK_PageUp: "⇞",
            kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
        ]

        if let special = specialKeys[keyCode] {
            return special
        }

        // Use TIS to get the character for regular keys
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "?"
        }

        let dataRef = unsafeBitCast(layoutData, to: CFData.self)
        let keyboardLayout = unsafeBitCast(CFDataGetBytePtr(dataRef), to: UnsafePointer<UCKeyboardLayout>.self)

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length: Int = 0

        let status = UCKeyTranslate(
            keyboardLayout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )

        if status == noErr && length > 0 {
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }

        return "?"
    }
}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @State var keyCode: Int = -1
        @State var modifiers: Int = 0

        var body: some View {
            VStack(spacing: 20) {
                KeyboardShortcutRecorder(keyCode: $keyCode, modifiers: $modifiers)
                Text("Key: \(keyCode), Mods: \(modifiers)")
            }
            .padding()
            .frame(width: 300)
        }
    }
    return PreviewWrapper()
}
