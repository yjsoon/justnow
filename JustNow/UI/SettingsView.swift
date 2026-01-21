//
//  SettingsView.swift
//  JustNow
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("captureInterval") private var captureInterval: Double = 0.5
    @AppStorage("reduceCaptureOnBattery") private var reduceCaptureOnBattery: Bool = true
    @AppStorage("shortcutKeyCode") private var shortcutKeyCode: Int = 15  // R key
    @AppStorage("shortcutModifiers") private var shortcutModifiers: Int = 1_572_864  // ⌘⌥

    var frameBuffer: FrameBuffer?
    var onShortcutChanged: (() -> Void)?

    @State private var storageSize: Int64 = 0
    @State private var frameCount: Int = 0
    @State private var showClearConfirmation = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Capture interval: \(String(format: "%.1f", captureInterval))s")
                    Slider(value: $captureInterval, in: 0.5...5.0, step: 0.5)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Retention: up to 24 hours")
                    Text("• Last 5m: every frame\n• 5–15m: every 5th\n• 15m–24h: every 30th")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Capture")
            }

            Section {
                HStack {
                    Text("Frames stored")
                    Spacer()
                    Text("\(frameCount)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Storage used")
                    Spacer()
                    Text(formatBytes(storageSize))
                        .foregroundStyle(.secondary)
                }

                Button("Clear All History", role: .destructive) {
                    showClearConfirmation = true
                }
            } header: {
                Text("Storage")
            }

            Section {
                Toggle("Reduce capture rate on battery", isOn: $reduceCaptureOnBattery)
                Text("When enabled, capture interval doubles when on battery power")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Battery")
            }

            Section {
                HStack {
                    Text("Show Timeline")
                    Spacer()
                    KeyboardShortcutRecorder(
                        keyCode: $shortcutKeyCode,
                        modifiers: $shortcutModifiers
                    )
                    .onChange(of: shortcutKeyCode) { onShortcutChanged?() }
                    .onChange(of: shortcutModifiers) { onShortcutChanged?() }
                }
                Text("Press **Escape** to dismiss the overlay")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Keyboard Shortcut")
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 420)
        .navigationTitle("JustNow Settings")
        .task {
            await updateStorageInfo()
        }
        .alert("Clear History?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear All", role: .destructive) {
                Task {
                    try? await frameBuffer?.clear()
                    await updateStorageInfo()
                }
            }
        } message: {
            Text("This will delete all captured frames. This cannot be undone.")
        }
    }

    private func updateStorageInfo() async {
        if let buffer = frameBuffer {
            storageSize = await buffer.totalStorageSize()
            frameCount = buffer.frameCount
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

#Preview {
    SettingsView()
}
