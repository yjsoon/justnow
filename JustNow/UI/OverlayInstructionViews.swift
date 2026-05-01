import SwiftUI

struct InstructionsOverlay: View {
    var viewModel: OverlayViewModel

    var body: some View {
        // The "drag" affordance flips to "drag for screenshot" whenever
        // we're in region-screenshot mode — either ⌘ is held, or the user
        // armed it via the "Save Region…" menu item.
        let dragLabel = viewModel.isInRegionScreenshotMode ? "Drag for screenshot" : "Drag to grab text"
        let dragIcon = viewModel.isInRegionScreenshotMode ? "camera.viewfinder" : "text.viewfinder"

        ViewThatFits(in: .horizontal) {
            instructionPill(dragLabel: dragLabel, dragIcon: dragIcon, showsSearchShortcut: FeatureFlags.isSearchEnabled)
            instructionPill(dragLabel: shortened(dragLabel, to: 1), dragIcon: dragIcon, showsSearchShortcut: FeatureFlags.isSearchEnabled)
            instructionPill(dragLabel: shortened(dragLabel, to: 2), dragIcon: dragIcon, showsSearchShortcut: FeatureFlags.isSearchEnabled)
            instructionPill(dragLabel: "", dragIcon: dragIcon, showsSearchShortcut: FeatureFlags.isSearchEnabled)
        }
    }

    private func shortened(_ full: String, to step: Int) -> String {
        // Mirror the previous "Drag to grab text" → "Grab text" → "Grab"
        // squeeze. For "Drag for screenshot" we go "For screenshot" → "Screenshot".
        switch (full, step) {
        case ("Drag to grab text", 1): return "Grab text"
        case ("Drag to grab text", 2): return "Grab"
        case ("Drag for screenshot", 1): return "For screenshot"
        case ("Drag for screenshot", 2): return "Screenshot"
        default: return full
        }
    }

    private func instructionPill(dragLabel: String, dragIcon: String, showsSearchShortcut: Bool) -> some View {
        HStack(spacing: 16) {
            Label("← →", systemImage: "arrow.left.arrow.right")
            if dragLabel.isEmpty {
                Image(systemName: dragIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                Label(dragLabel, systemImage: dragIcon)
            }
            Label("\u{2318}S", systemImage: "camera.viewfinder")
            if showsSearchShortcut {
                Label("/", systemImage: "magnifyingglass")
            }
        }
        .labelStyle(CompactInstructionLabelStyle())
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.7))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .darkBarBackground(in: Capsule())
    }
}

struct CompactInstructionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
            configuration.title
        }
    }
}

struct OverlayMoreMenuIsland: View {
    var viewModel: OverlayViewModel

    var body: some View {
        Menu {
            Button {
                viewModel.saveCurrentFrameToScreenshotsLocation()
            } label: {
                Label("Save Screenshot", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!viewModel.canSaveCurrentFrame)

            Button {
                viewModel.armRegionScreenshot()
            } label: {
                Label("Save Region…", systemImage: "rectangle.dashed")
            }
            .disabled(!viewModel.canSaveCurrentFrame)

            Divider()

            Button {
                viewModel.openSettings()
            } label: {
                Label("Open Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .darkBarBackground(in: Circle())
        .help("More actions")
        .accessibilityLabel("More actions")
        .accessibilityHint("Save the current screenshot, save a region, or open Settings.")
    }
}
