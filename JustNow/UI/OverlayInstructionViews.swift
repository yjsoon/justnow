import SwiftUI

struct InstructionsOverlay: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            instructionPill(textGrabLabel: "drag to grab text", showsSearchShortcut: FeatureFlags.isSearchEnabled)
            instructionPill(textGrabLabel: "grab text", showsSearchShortcut: FeatureFlags.isSearchEnabled)
            instructionPill(textGrabLabel: "grab", showsSearchShortcut: FeatureFlags.isSearchEnabled)
            instructionPill(textGrabLabel: "", showsSearchShortcut: FeatureFlags.isSearchEnabled)
        }
    }

    private func instructionPill(textGrabLabel: String, showsSearchShortcut: Bool) -> some View {
        HStack(spacing: 16) {
            Label("← →", systemImage: "arrow.left.arrow.right")
            if textGrabLabel.isEmpty {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                Label(textGrabLabel, systemImage: "text.viewfinder")
            }
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
