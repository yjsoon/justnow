//
//  ScreenshotSaveLocationSettingsSection.swift
//  JustNow
//

import AppKit
import SwiftUI

/// Settings section that lets the user pick a custom destination for
/// screenshots saved from the rewind overlay (⌘S / "Save Screenshot…").
///
/// The control follows the resolution chain implemented in
/// `ScreenshotSaveLocation.resolveLive`: an explicit override here wins over
/// the macOS system screenshot location, which in turn wins over `~/Desktop`.
struct ScreenshotSaveLocationSettingsSection: View {
    @Binding var overridePath: String

    /// Bumped on appear, when the override changes, and after picking a
    /// folder, so the resolved path display refreshes against the live system
    /// screenshot location.
    @State private var refreshTick: Int = 0

    private var resolvedURL: URL {
        _ = refreshTick
        return ScreenshotSaveLocation.resolveLive()
    }

    private var trimmedOverride: String {
        overridePath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent {
                Text(displayPath(for: resolvedURL))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } label: {
                Text("Saving to")
            }

            if !trimmedOverride.isEmpty {
                LabeledContent {
                    Text(displayPath(for: URL(fileURLWithPath: (trimmedOverride as NSString).expandingTildeInPath, isDirectory: true)))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } label: {
                    Text("Override")
                }
            }

            HStack(spacing: 8) {
                Button("Choose folder…") {
                    chooseFolder()
                }

                Button("Use system default") {
                    overridePath = ""
                    refreshTick &+= 1
                }
                .disabled(trimmedOverride.isEmpty)

                Spacer()
            }

            Text("Screenshots saved with ⌘S in rewind go to your override if it's set, otherwise to the macOS system screenshot folder, otherwise to your Desktop.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { refreshTick &+= 1 }
        .onChange(of: overridePath) { _, _ in refreshTick &+= 1 }
    }

    // MARK: - Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.title = "Choose screenshot save location"

        let trimmed = trimmedOverride
        if !trimmed.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
        }

        if panel.runModal() == .OK, let url = panel.url {
            overridePath = url.path
            refreshTick &+= 1
        }
    }

    // MARK: - Display helpers

    /// Render a URL as a path with `~` for the home directory, matching how
    /// Finder and most macOS preferences surfaces show user paths.
    private func displayPath(for url: URL) -> String {
        let path = url.path
        let home = NSHomeDirectory()
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
