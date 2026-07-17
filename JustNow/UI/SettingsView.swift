//
//  SettingsView.swift
//  JustNow
//

import SwiftUI
import Sparkle
import Foundation
import AppKit

struct SettingsView: View {
    @AppStorage(AppStorageKey.captureInterval) private var captureInterval: Double = AppStorageDefault.captureInterval
    @AppStorage(AppStorageKey.rewindHistorySeconds)
    private var rewindHistorySeconds: Double = AppStorageDefault.rewindHistorySeconds
    @AppStorage(AppStorageKey.recentTimelineWindowSeconds)
    private var recentTimelineWindowSeconds: Double = AppStorageDefault.recentTimelineWindowSeconds
    @AppStorage(AppStorageKey.reduceCaptureOnBattery) private var reduceCaptureOnBattery: Bool = AppStorageDefault.reduceCaptureOnBattery
    @AppStorage(AppStorageKey.shortcutKeyCode) private var shortcutKeyCode: Int = AppStorageDefault.shortcutKeyCode
    @AppStorage(AppStorageKey.shortcutModifiers) private var shortcutModifiers: Int = AppStorageDefault.shortcutModifiers
    @AppStorage(AppStorageKey.capturePauseShortcutKeyCode) private var capturePauseShortcutKeyCode: Int = AppStorageDefault.capturePauseShortcutKeyCode
    @AppStorage(AppStorageKey.capturePauseShortcutModifiers) private var capturePauseShortcutModifiers: Int = AppStorageDefault.capturePauseShortcutModifiers
    @AppStorage(AppStorageKey.overlayDismissKeyCode) private var overlayDismissKeyCode: Int = AppStorageDefault.overlayDismissKeyCode
    @AppStorage(AppStorageKey.overlayDismissModifiers) private var overlayDismissModifiers: Int = AppStorageDefault.overlayDismissModifiers
    @AppStorage(AppStorageKey.textGrabSoundEnabled) private var textGrabSoundEnabled: Bool = AppStorageDefault.textGrabSoundEnabled
    @AppStorage(AppStorageKey.saveScreenshotSoundEnabled) private var saveScreenshotSoundEnabled: Bool = AppStorageDefault.saveScreenshotSoundEnabled
    @AppStorage(AppStorageKey.textGrabDebugPreviewEnabled) private var textGrabDebugPreviewEnabled: Bool = AppStorageDefault.textGrabDebugPreviewEnabled
    @AppStorage(AppStorageKey.rewindDragAction) private var rewindDragAction: String = AppStorageDefault.rewindDragAction
    @AppStorage(AppStorageKey.showMenuBarIcon) private var showMenuBarIcon: Bool = AppStorageDefault.showMenuBarIcon
    @AppStorage(AppStorageKey.hasSeenMenuBarHideInfo) private var hasSeenMenuBarHideInfo: Bool = AppStorageDefault.hasSeenMenuBarHideInfo
    @AppStorage(AppStorageKey.screenshotSaveLocationOverride)
    private var screenshotSaveLocationOverride: String = AppStorageDefault.screenshotSaveLocationOverride
    @AppStorage(AppStorageKey.screenshotSaveToFolder) private var screenshotSaveToFolder: Bool = AppStorageDefault.screenshotSaveToFolder
    @AppStorage(AppStorageKey.screenshotSaveToClipboard) private var screenshotSaveToClipboard: Bool = AppStorageDefault.screenshotSaveToClipboard
    @State private var showHideIconInfoAlert: Bool = false

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

    var body: some View {
        TabView {
            generalSettingsTab
            rewindSettingsTab
            captureSettingsTab
            shortcutsSettingsTab
        }
        .tabViewStyle(.tabBarOnly)
        .frame(width: 660, height: 520)
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
        .task {
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
        .alert("Menu bar icon hidden", isPresented: $showHideIconInfoAlert) {
            Button("Got it", role: .cancel) { }
        } message: {
            Text("To bring it back, relaunch JustNow from Finder or Spotlight to reopen Settings, or switch it back on from the rewind overlay.")
        }
    }

    private var generalSettingsTab: some View {
        Form {
            Section("Launch") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Launch on startup", isOn: launchAtLoginBinding)
                        .disabled(!context.canConfigureLaunchAtLogin)

                    Text("If macOS asks for approval, enable JustNow in System Settings > General > Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                        .onChange(of: showMenuBarIcon) { _, newValue in
                            if !newValue && !hasSeenMenuBarHideInfo {
                                showHideIconInfoAlert = true
                                hasSeenMenuBarHideInfo = true
                            }
                        }

                    Text("Hides the icon in the macOS menu bar. If you lose access, relaunch JustNow from Finder or Spotlight to reopen Settings, or toggle it back from the rewind overlay.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Software Update") {
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
            }
        }
        .formStyle(.grouped)
        .tabItem {
            Text("General")
        }
    }

    private var rewindSettingsTab: some View {
        Form {
            Section("Text and screenshots") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent {
                        Picker("", selection: $rewindDragAction) {
                            ForEach(RewindDragAction.allCases) { action in
                                Text(action.settingsLabel).tag(action.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    } label: {
                        Text("Default drag action")
                    }

                    Text("Choose what happens when you drag over a rewind frame. Hold Command while dragging for the other action. Screenshots follow your screenshot save location settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("Play copied-text sound", isOn: $textGrabSoundEnabled)

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Show text-grab debug preview", isOn: $textGrabDebugPreviewEnabled)

                    Text("Copied text is cleaned up before it lands on the clipboard. Debug preview shows the exact crop sent into OCR.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Screenshot save location") {
                ScreenshotSaveLocationSettingsSection(
                    overridePath: $screenshotSaveLocationOverride,
                    saveToFolder: $screenshotSaveToFolder,
                    saveToClipboard: $screenshotSaveToClipboard,
                    saveScreenshotSoundEnabled: $saveScreenshotSoundEnabled
                )
            }
        }
        .formStyle(.grouped)
        .tabItem {
            Text("Rewind")
        }
    }

    private var captureSettingsTab: some View {
        Form {
            Section("Capture") {
                LabeledContent {
                    HStack(spacing: 8) {
                        Slider(value: resolvedCaptureInterval, in: CaptureIntervalSetting.allowedRange, step: 0.25)
                            .frame(width: 180)

                        Text(captureIntervalLabel)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 96, alignment: .trailing)
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

                    Text("Recent history keeps every stored frame. Older history gradually uses fewer frames so longer rewind windows stay manageable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent {
                        Picker("", selection: $recentTimelineWindowSeconds) {
                            ForEach(RecentTimelineWindow.allCases) { window in
                                Text(window.label).tag(window.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .accessibilityLabel("Full-detail window")
                    } label: {
                        Text("Full-detail window")
                    }

                    Text("Choose how long scrolling keeps every stored frame before the gradual falloff begins.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Battery") {
                Toggle("Reduce power use automatically", isOn: $reduceCaptureOnBattery)
                Text("On battery / in Low Power Mode / under thermal pressure / when idle for a while: This setting makes JustNow capture less often, save lower-quality images, and slow background search indexing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Storage") {
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

                HStack(spacing: 8) {
                    Button("Open Storage Folder") {
                        openStorageFolder()
                    }

                    Spacer()

                    Button("Clear All History", role: .destructive) {
                        showClearConfirmation = true
                    }
                }
            }

            Section("Search Diagnostics") {
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

                        Text("These numbers update every 2 seconds from local telemetry.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Local search telemetry")
                }
            }
        }
        .formStyle(.grouped)
        .tabItem {
            Text("Capture")
        }
    }

    private var shortcutsSettingsTab: some View {
        Form {
            Section("Keyboard Shortcuts") {
                shortcutRow("Open rewind") {
                    KeyboardShortcutRecorder(
                        keyCode: $shortcutKeyCode,
                        modifiers: $shortcutModifiers
                    )
                    .frame(maxWidth: 240)
                    .onChange(of: shortcutKeyCode) { _, _ in context.notifyShortcutChanged() }
                    .onChange(of: shortcutModifiers) { _, _ in context.notifyShortcutChanged() }
                }

                shortcutRow("Pause or resume recording") {
                    KeyboardShortcutRecorder(
                        keyCode: $capturePauseShortcutKeyCode,
                        modifiers: $capturePauseShortcutModifiers
                    )
                    .frame(maxWidth: 240)
                    .onChange(of: capturePauseShortcutKeyCode) { _, _ in context.notifyShortcutChanged() }
                    .onChange(of: capturePauseShortcutModifiers) { _, _ in context.notifyShortcutChanged() }
                }

                shortcutRow("Close rewind") {
                    KeyboardShortcutRecorder(
                        keyCode: $overlayDismissKeyCode,
                        modifiers: $overlayDismissModifiers,
                        allowsEscapeShortcut: true,
                        placeholder: "Press key"
                    )
                    .frame(maxWidth: 240)
                    .onChange(of: overlayDismissKeyCode) { _, _ in context.notifyShortcutChanged() }
                    .onChange(of: overlayDismissModifiers) { _, _ in context.notifyShortcutChanged() }
                }

                Text("These shortcuts work across macOS while JustNow is running. Keep each action on a distinct shortcut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let shortcutConflictMessage {
                    Text(shortcutConflictMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .tabItem {
            Text("Shortcuts")
        }
    }

    private var captureIntervalLabel: String {
        let resolvedInterval = CaptureIntervalSetting.resolved(from: captureInterval)
        let seconds = resolvedInterval.formatted(
            .number.precision(.fractionLength(0...2))
        )
        let framesPerSecond = (1 / resolvedInterval).formatted(
            .number.precision(.fractionLength(0...1))
        )
        return "\(seconds)s · up to \(framesPerSecond) fps"
    }

    private var resolvedCaptureInterval: Binding<Double> {
        Binding(
            get: { CaptureIntervalSetting.resolved(from: captureInterval) },
            set: { captureInterval = CaptureIntervalSetting.resolved(from: $0) }
        )
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

    private func openStorageFolder() {
        let applicationSupportURL =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let storageURL = applicationSupportURL.appendingPathComponent("JustNow", isDirectory: true)
        try? FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(storageURL)
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
        return bytes.formatted(.byteCount(style: .file))
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

    @ViewBuilder
    private func shortcutRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        LabeledContent {
            content()
                .frame(width: 240, alignment: .trailing)
        } label: {
            Text(title)
        }
    }

    private var shortcutConflictMessage: String? {
        let shortcuts: [(label: String, keyCode: Int, modifiers: Int)] = [
            ("Open rewind", shortcutKeyCode, shortcutModifiers),
            ("Pause or resume recording", capturePauseShortcutKeyCode, capturePauseShortcutModifiers),
            ("Close rewind", overlayDismissKeyCode, overlayDismissModifiers)
        ]

        for index in shortcuts.indices {
            let current = shortcuts[index]
            guard current.keyCode != -1 else { continue }

            guard index + 1 < shortcuts.count else { continue }

            for comparisonIndex in (index + 1)..<shortcuts.count {
                let comparison = shortcuts[comparisonIndex]
                guard comparison.keyCode != -1 else { continue }

                if current.keyCode == comparison.keyCode && current.modifiers == comparison.modifiers {
                    return "\(current.label) and \(comparison.label) should not share the same shortcut."
                }
            }
        }

        return nil
    }
}

#Preview {
    SettingsView()
}
