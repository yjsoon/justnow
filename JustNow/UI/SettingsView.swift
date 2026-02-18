//
//  SettingsView.swift
//  JustNow
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("captureInterval") private var captureInterval: Double = 0.5
    @AppStorage("reduceCaptureOnBattery") private var reduceCaptureOnBattery: Bool = true
    @AppStorage("backgroundSearchIndexingEnabled") private var backgroundSearchIndexingEnabled: Bool = true
    @AppStorage("shortcutKeyCode") private var shortcutKeyCode: Int = 15  // R key
    @AppStorage("shortcutModifiers") private var shortcutModifiers: Int = 1_572_864  // ⌘⌥

    var frameBuffer: FrameBuffer?
    var onShortcutChanged: (() -> Void)?

    @State private var storageSize: Int64 = 0
    @State private var frameCount: Int = 0
    @State private var showClearConfirmation = false
    @State private var telemetrySnapshot: SearchTelemetrySnapshot = .empty
    @State private var isSearchDiagnosticsExpanded = false

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
                Text("When enabled, capture interval increases and image quality is reduced on battery power, thermal pressure, or extended idle time")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Background OCR indexing for search", isOn: $backgroundSearchIndexingEnabled)
                Text("Indexes recent frames in the background so searches return faster. Automatically throttled on battery, low power mode, and thermal pressure.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Battery")
            }

            Section {
                DisclosureGroup(isExpanded: $isSearchDiagnosticsExpanded) {
                    VStack(spacing: 10) {
                        HStack {
                            Text("Index queue")
                            Spacer()
                            Text("\(telemetrySnapshot.queueDepth) / \(telemetrySnapshot.queueCapacity)")
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("OCR throughput")
                            Spacer()
                            Text("\(formatRate(telemetrySnapshot.ocrPerSecond))")
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("OCR duration (avg/p95)")
                            Spacer()
                            Text("\(formatSeconds(telemetrySnapshot.averageOCRDuration)) / \(formatSeconds(telemetrySnapshot.p95OCRDuration))")
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("Index lag (avg/p95)")
                            Spacer()
                            Text("\(formatSeconds(telemetrySnapshot.averageIndexLag)) / \(formatSeconds(telemetrySnapshot.p95IndexLag))")
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("Warm search p50")
                            Spacer()
                            Text("\(formatSeconds(telemetrySnapshot.warmSearchP50)) · n=\(telemetrySnapshot.warmSearchCount)")
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("Cold search p50")
                            Spacer()
                            Text("\(formatSeconds(telemetrySnapshot.coldSearchP50)) · n=\(telemetrySnapshot.coldSearchCount)")
                                .foregroundStyle(.secondary)
                        }

                        Text("These numbers update every 2 seconds from local telemetry.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Search Diagnostics")
                }
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
        .frame(width: 460, height: 560)
        .navigationTitle("JustNow Settings")
        .task {
            await updateStorageInfo()
        }
        .task {
            await refreshTelemetryLoop()
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

    private func refreshTelemetryLoop() async {
        while !Task.isCancelled {
            let snapshot = await SearchTelemetry.shared.snapshot()
            await MainActor.run {
                telemetrySnapshot = snapshot
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatRate(_ value: Double) -> String {
        String(format: "%.2f/s", value)
    }

    private func formatSeconds(_ value: TimeInterval) -> String {
        String(format: "%.2fs", value)
    }
}

#Preview {
    SettingsView()
}
