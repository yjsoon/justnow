//
//  SettingsView.swift
//  JustNow
//

import SwiftUI
import Sparkle

struct SettingsView: View {
    @AppStorage("captureInterval") private var captureInterval: Double = 0.5
    @AppStorage("rewindHistorySeconds")
    private var rewindHistorySeconds: Double = RewindHistoryOption.defaultValue.rawValue
    @AppStorage("recentTimelineWindowSeconds")
    private var recentTimelineWindowSeconds: Double = RecentTimelineWindow.defaultValue.rawValue
    @AppStorage("reduceCaptureOnBattery") private var reduceCaptureOnBattery: Bool = true
    @AppStorage("keepConfiguredCaptureCadenceOnBattery")
    private var keepConfiguredCaptureCadenceOnBattery: Bool = true
    @AppStorage("backgroundSearchIndexingEnabled") private var backgroundSearchIndexingEnabled: Bool = true
    @AppStorage("shortcutKeyCode") private var shortcutKeyCode: Int = 38  // J key
    @AppStorage("shortcutModifiers") private var shortcutModifiers: Int = 1_572_864  // ⌘⌥
    @AppStorage("overlayDismissKeyCode") private var overlayDismissKeyCode: Int = 53
    @AppStorage("overlayDismissModifiers") private var overlayDismissModifiers: Int = 0

    var context: SettingsContext = SettingsContext()

    @State private var storageSize: Int64 = 0
    @State private var frameCount: Int = 0
    @State private var showClearConfirmation = false
    @State private var telemetrySnapshot: SearchTelemetrySnapshot = .empty
    @State private var isSearchDiagnosticsExpanded = false
    @State private var automaticallyChecksForUpdates = false
    @State private var automaticallyDownloadsUpdates = false
    @State private var allowsAutomaticUpdates = false
    @State private var launchAtLoginEnabled = false
    @State private var launchAtLoginAlertMessage: String?

    private var isSearchEnabled: Bool {
        FeatureFlags.isSearchEnabled
    }

    var body: some View {
        Form {
            Section {
                Toggle("Launch on startup", isOn: launchAtLoginBinding)
                    .disabled(!context.canConfigureLaunchAtLogin)

                Text("If macOS asks for approval, enable JustNow in System Settings > General > Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Show")
                    Spacer()
                    KeyboardShortcutRecorder(
                        keyCode: $shortcutKeyCode,
                        modifiers: $shortcutModifiers
                    )
                    .frame(maxWidth: 240)
                    .onChange(of: shortcutKeyCode) { _, _ in context.notifyShortcutChanged() }
                    .onChange(of: shortcutModifiers) { _, _ in context.notifyShortcutChanged() }
                }

                HStack {
                    Text("Hide")
                    Spacer()
                    KeyboardShortcutRecorder(
                        keyCode: $overlayDismissKeyCode,
                        modifiers: $overlayDismissModifiers,
                        allowsEscapeShortcut: true,
                        placeholder: "Press key"
                    )
                    .frame(maxWidth: 240)
                }
            } header: {
                Text("General")
            }

            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        Slider(value: $captureInterval, in: 0.5...5.0, step: 0.5)
                            .frame(width: 180)

                        Text("\(captureInterval, specifier: "%.1f")s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Text("Capture interval")
                }

                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent {
                        Picker("", selection: $rewindHistorySeconds) {
                            ForEach(RewindHistoryOption.allCases) { option in
                                Text(option.settingsLabel).tag(option.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    } label: {
                        Text("Rewind history")
                    }

                    Text("Recent history stays at full detail. Older history is compacted automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent {
                        Picker(selection: $recentTimelineWindowSeconds) {
                            ForEach(RecentTimelineWindow.allCases) { window in
                                Text(window.label).tag(window.rawValue)
                            }
                        } label: {
                            EmptyView()
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityLabel("Full-detail window")
                        .frame(width: 220)
                    } label: {
                        Text("Full-detail window")
                    }

                    Text("Keep every stored frame in this most recent window, then collapse visually similar older history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                Text("When enabled, JustNow can lower image quality and throttle background work on battery power, thermal pressure, or extended idle time. Capture cadence only changes if the setting below is off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Keep configured capture cadence on battery", isOn: $keepConfiguredCaptureCadenceOnBattery)
                    .disabled(!reduceCaptureOnBattery)
                Text("Preserves the interval you chose when unplugged or in Low Power Mode. Battery savings come from lower image quality and background throttling instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if isSearchEnabled {
                    Toggle("Background OCR indexing for search", isOn: $backgroundSearchIndexingEnabled)
                    Text("Indexes recent frames in the background so searches return faster. Automatically throttled on battery, low power mode, and thermal pressure.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Battery")
            }

            if isSearchEnabled {
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
            }

            Section {
                Button("Check for Updates…") {
                    context.checkForUpdates()
                }
                .disabled(!(context.updater?.canCheckForUpdates ?? false))

                Toggle("Check for updates automatically", isOn: automaticChecksBinding)

                Toggle("Download updates automatically", isOn: automaticDownloadsBinding)
                    .disabled(!allowsAutomaticUpdates)

                Text("JustNow uses Sparkle to deliver signed updates from the public appcast at justnow.tk.sg.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Software Update")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
        .navigationTitle("JustNow Settings")
        .task {
            await updateStorageInfo()
        }
        .task(id: frameBufferIdentity) {
            await updateStorageInfo()
        }
        .task(id: updaterIdentity) {
            syncUpdaterState()
        }
        .task(id: launchAtLoginIdentity) {
            syncLaunchAtLoginState()
        }
        .task(id: isSearchEnabled) {
            guard isSearchEnabled else {
                telemetrySnapshot = .empty
                return
            }
            await refreshTelemetryLoop()
        }
        .alert("Clear History?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear All", role: .destructive) {
                Task {
                    try? await context.frameBuffer?.clear()
                    await updateStorageInfo()
                }
            }
        } message: {
            Text("This will delete all captured frames. This cannot be undone.")
        }
        .alert("Launch on startup", isPresented: launchAtLoginAlertIsPresented) {
            Button("OK", role: .cancel) {
                launchAtLoginAlertMessage = nil
            }
        } message: {
            Text(launchAtLoginAlertMessage ?? "")
        }
    }

    private func updateStorageInfo() async {
        if let buffer = context.frameBuffer {
            let bufferIdentity = ObjectIdentifier(buffer)
            let totalStorageSize = await buffer.totalStorageSize()
            guard !Task.isCancelled, context.frameBuffer.map(ObjectIdentifier.init) == bufferIdentity else { return }
            storageSize = totalStorageSize
            frameCount = buffer.frameCount
        } else {
            storageSize = 0
            frameCount = 0
        }
    }

    private var frameBufferIdentity: ObjectIdentifier? {
        context.frameBuffer.map(ObjectIdentifier.init)
    }

    private var updaterIdentity: ObjectIdentifier? {
        context.updater.map(ObjectIdentifier.init)
    }

    private var launchAtLoginIdentity: ObjectIdentifier? {
        context.launchAtLoginManager.map(ObjectIdentifier.init)
    }

    private func refreshTelemetryLoop() async {
        while !Task.isCancelled {
            let snapshot = await SearchTelemetry.shared.snapshot()
            guard !Task.isCancelled else { return }
            telemetrySnapshot = snapshot
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

    private var automaticChecksBinding: Binding<Bool> {
        Binding(
            get: { automaticallyChecksForUpdates },
            set: { newValue in
                automaticallyChecksForUpdates = newValue
                context.updater?.automaticallyChecksForUpdates = newValue
                syncUpdaterState()
            }
        )
    }

    private var automaticDownloadsBinding: Binding<Bool> {
        Binding(
            get: { automaticallyDownloadsUpdates },
            set: { newValue in
                automaticallyDownloadsUpdates = newValue
                context.updater?.automaticallyDownloadsUpdates = newValue
                syncUpdaterState()
            }
        )
    }

    private func syncUpdaterState() {
        guard let updater = context.updater else {
            automaticallyChecksForUpdates = false
            automaticallyDownloadsUpdates = false
            allowsAutomaticUpdates = false
            return
        }

        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        allowsAutomaticUpdates = updater.allowsAutomaticUpdates
    }

    private func syncLaunchAtLoginState() {
        launchAtLoginEnabled = context.launchAtLoginEnabled()
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginEnabled },
            set: { newValue in
                let previousValue = launchAtLoginEnabled
                launchAtLoginEnabled = newValue

                do {
                    let result = try context.setLaunchAtLoginEnabled(newValue)
                    syncLaunchAtLoginState()

                    if result == .requiresApproval {
                        launchAtLoginAlertMessage = "macOS needs approval before JustNow can launch at startup. Enable JustNow in System Settings > General > Login Items."
                    }
                } catch {
                    launchAtLoginEnabled = previousValue
                    launchAtLoginAlertMessage = error.localizedDescription
                }
            }
        )
    }

    private var launchAtLoginAlertIsPresented: Binding<Bool> {
        Binding(
            get: { launchAtLoginAlertMessage != nil },
            set: { isPresented in
                if !isPresented {
                    launchAtLoginAlertMessage = nil
                }
            }
        )
    }
}

#Preview {
    SettingsView()
}
