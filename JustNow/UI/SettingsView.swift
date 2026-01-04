//
//  SettingsView.swift
//  JustNow
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("captureInterval") private var captureInterval: Double = 1.0
    @AppStorage("maxFrames") private var maxFrames: Int = 600
    @AppStorage("reduceCaptureOnBattery") private var reduceCaptureOnBattery: Bool = true

    var frameBuffer: FrameBuffer?

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

                VStack(alignment: .leading, spacing: 8) {
                    Text("Max frames: \(maxFrames)")
                    Slider(value: Binding(
                        get: { Double(maxFrames) },
                        set: { maxFrames = Int($0) }
                    ), in: 100...1200, step: 100)
                    Text("≈ \(Int(Double(maxFrames) * captureInterval / 60)) minutes of history")
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
                Text("Press **⌘⌥R** to show the timeline overlay")
                    .font(.callout)
                Text("Press **Escape** to dismiss")
                    .font(.callout)
            } header: {
                Text("Keyboard Shortcuts")
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
