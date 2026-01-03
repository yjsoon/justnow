//
//  SettingsView.swift
//  JustNow
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("captureInterval") private var captureInterval: Double = 1.0
    @AppStorage("maxFrames") private var maxFrames: Int = 600
    @AppStorage("reduceCaptureOnBattery") private var reduceCaptureOnBattery: Bool = true

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Capture interval: \(String(format: "%.1f", captureInterval))s")
                    Slider(value: $captureInterval, in: 0.5...5.0, step: 0.5)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Max frames in memory: \(maxFrames)")
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
        .frame(width: 400, height: 350)
        .navigationTitle("JustNow Settings")
    }
}

#Preview {
    SettingsView()
}
