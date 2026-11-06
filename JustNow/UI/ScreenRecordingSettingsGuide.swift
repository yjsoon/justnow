import AppKit
import SwiftUI

/// A small hint that rides along the bottom of System Settings while the user
/// grants Screen Recording. Its JustNow row can be dragged into the app list,
/// which adds JustNow without the `+` file picker.
///
/// It only shows while System Settings is frontmost. It closes when the user
/// explicitly comes back to JustNow (reopening it, its menu, or its alerts),
/// not when JustNow merely becomes active or a grant seems to land: the running
/// process cannot rely on preflight mid-grant, and system sheets during the
/// grant can shift activation without the user leaving Settings.
@MainActor
final class ScreenRecordingSettingsGuide {
    static let shared = ScreenRecordingSettingsGuide()

    static let screenRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
    )!

    private static let systemSettingsBundleID = "com.apple.systempreferences"
    private static let followInterval: TimeInterval = 0.2

    private var panel: NSPanel?
    private var followTimer: Timer?
    /// The alert's frame; the first placement grows out of it.
    private var launchFrame: CGRect?
    private var isAnimatingIn = false
    /// A drag from the guide's row is in flight. Hiding or closing the panel
    /// then would cancel the drop, so both wait until it ends.
    var isDragging = false {
        didSet {
            guard !isDragging, let reason = closeAfterDrag else { return }
            closeAfterDrag = nil
            close(reason)
        }
    }
    private var closeAfterDrag: CloseReason?

    /// Why the guide closed, logged without content so a report shows which
    /// path ended it. Only explicit returns to JustNow and × close it: macOS
    /// does not apply a grant to the running process, and preflight can read
    /// true briefly mid-grant, so the grant itself is not a reason.
    enum CloseReason: String {
        case replaced, closeButton, reopen, statusMenu, timeline, permissionAlert, restartAlert
    }

    /// Opens the Screen Recording pane and starts following its window.
    func show(launchingFrom alertFrame: CGRect?) {
        close(.replaced)
        launchFrame = alertFrame.flatMap { $0.isEmpty ? nil : $0 }
        panel = Self.makePanel(onClose: { [weak self] in self?.close(.closeButton) })
        // Poll for as long as the guide is open, including while it is hidden:
        // focus can return to Settings without an activation notification (for
        // example after a system sheet), and frontmostApplication can lag one.
        followTimer = Timer.scheduledTimer(withTimeInterval: Self.followInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        NSWorkspace.shared.open(Self.screenRecordingSettingsURL)
        follow()
    }

    func close(_ reason: CloseReason) {
        guard panel != nil else { return }
        guard !isDragging else {
            closeAfterDrag = reason
            DiagnosticsLog.shared.log("Permission", "Screen Recording guide close deferred until drag ends; reason=\(reason.rawValue)")
            return
        }
        DiagnosticsLog.shared.log("Permission", "Screen Recording guide closed; reason=\(reason.rawValue)")
        followTimer?.invalidate()
        followTimer = nil
        panel?.orderOut(nil)
        panel = nil
        launchFrame = nil
        isAnimatingIn = false
    }

    private func follow() {
        guard let panel, !isDragging else { return }

        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.systemSettingsBundleID else {
            panel.orderOut(nil)
            return
        }

        guard let window = Self.systemSettingsWindow() else {
            panel.orderOut(nil)
            return
        }
        let target = ScreenRecordingSettingsGuideLayout.guideFrame(
            size: panel.frame.size,
            settingsWindow: window.frame,
            visibleFrame: window.visibleFrame
        )

        if let start = launchFrame {
            launchFrame = nil
            isAnimatingIn = true
            panel.setFrame(start, display: false)
            panel.alphaValue = 0.85
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            } completionHandler: { [weak self] in
                // A guide shown again mid-animation has a new panel; leave its flag alone.
                MainActor.assumeIsolated {
                    guard let self, self.panel === panel else { return }
                    self.isAnimatingIn = false
                }
            }
            return
        }

        guard !isAnimatingIn else { return }
        if panel.frame != target {
            panel.setFrame(target, display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    /// The largest on-screen System Settings window, in AppKit coordinates.
    /// Window bounds are readable without Screen Recording permission.
    private static func systemSettingsWindow() -> (frame: CGRect, visibleFrame: CGRect)? {
        let pids = Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: systemSettingsBundleID)
                .map(\.processIdentifier)
        )
        guard !pids.isEmpty,
              let primaryScreen = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }

        let largest = windows
            .filter { info in
                (info[kCGWindowOwnerPID as String] as? pid_t).map(pids.contains) == true
                    && info[kCGWindowLayer as String] as? Int == 0
            }
            .compactMap { info -> CGRect? in
                guard let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
                return CGRect(dictionaryRepresentation: bounds)
            }
            .filter { $0.width >= 300 && $0.height >= 200 }
            .max { $0.width * $0.height < $1.width * $1.height }
        guard let largest else { return nil }

        let frame = ScreenRecordingSettingsGuideLayout.appKitFrame(
            fromWindowBounds: largest,
            primaryScreenHeight: primaryScreen.frame.height
        )
        let screen = NSScreen.screens.max {
            $0.frame.intersection(frame).width * $0.frame.intersection(frame).height
                < $1.frame.intersection(frame).width * $1.frame.intersection(frame).height
        } ?? primaryScreen
        return (frame, screen.visibleFrame)
    }

    private static func makePanel(onClose: @escaping () -> Void) -> NSPanel {
        let bundle = Bundle.main
        let appName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? bundle.bundleURL.deletingPathExtension().lastPathComponent
        let content = ScreenRecordingSettingsGuideView(
            appName: appName,
            appURL: bundle.bundleURL,
            appIcon: NSWorkspace.shared.icon(forFile: bundle.bundleURL.path),
            onClose: onClose
        )
        let hostingView = ClickThroughHostingView(rootView: content)
        let size = hostingView.fittingSize

        let panel = GuidePanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }
}

enum ScreenRecordingSettingsGuideLayout {
    /// System Settings' sidebar, which the guide should not cover.
    static let sidebarWidth: CGFloat = 200
    static let bottomInset: CGFloat = 16
    static let screenMargin: CGFloat = 8

    /// Converts a Quartz window rectangle (origin at the top left of the
    /// primary display, y down) to AppKit screen coordinates (y up).
    static func appKitFrame(fromWindowBounds bounds: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: bounds.minX,
            y: primaryScreenHeight - bounds.maxY,
            width: bounds.width,
            height: bounds.height
        )
    }

    /// Centres the guide over Settings' content pane, just above the window's
    /// bottom edge, and keeps it fully on the window's screen.
    static func guideFrame(size: CGSize, settingsWindow: CGRect, visibleFrame: CGRect) -> CGRect {
        let contentMinX = settingsWindow.minX + min(sidebarWidth, settingsWindow.width / 3)
        let preferredX = (contentMinX + settingsWindow.maxX - size.width) / 2
        let preferredY = settingsWindow.minY + bottomInset
        let x = min(max(preferredX, visibleFrame.minX + screenMargin), visibleFrame.maxX - size.width - screenMargin)
        let y = min(max(preferredY, visibleFrame.minY + screenMargin), visibleFrame.maxY - size.height - screenMargin)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

struct ScreenRecordingSettingsGuideView: View {
    let appName: String
    let appURL: URL
    let appIcon: NSImage
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentColor)
                Text("Drag \(appName) into the list above to allow Screen Recording")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Hide this hint")
                .accessibilityLabel("Hide this hint")
            }

            HStack(spacing: 10) {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 28, height: 28)
                Text(appName)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Image(systemName: "hand.draw")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 42)
            .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .overlay(AppBundleDragSource(url: appURL, icon: appIcon))
            .accessibilityElement(children: .combine)
            .accessibilityHint("Drag into the Screen Recording list")
        }
        .padding(14)
        .frame(width: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
    }
}

/// Starts a Finder-style drag of the app bundle, which the Screen Recording
/// list accepts as a new entry.
private struct AppBundleDragSource: NSViewRepresentable {
    let url: URL
    let icon: NSImage

    func makeNSView(context: Context) -> DragView {
        DragView(url: url, icon: icon)
    }

    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView, NSDraggingSource {
        private let url: URL
        private let icon: NSImage

        init(url: URL, icon: NSImage) {
            self.url = url
            self.icon = icon
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // Keep the press here so the drag events that follow come to this view.
        override func mouseDown(with event: NSEvent) {}

        override func mouseDragged(with event: NSEvent) {
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let location = convert(event.locationInWindow, from: nil)
            let side: CGFloat = 32
            item.setDraggingFrame(
                CGRect(x: location.x - side / 2, y: location.y - side / 2, width: side, height: side),
                contents: icon
            )
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            ScreenRecordingSettingsGuide.shared.isDragging = true
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            ScreenRecordingSettingsGuide.shared.isDragging = false
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .link, .generic] : []
        }
    }
}

/// The guide never becomes key, so its controls must act on the first click.
/// Not generic: Swift 6.3.3 (Xcode 26.6) crashes in EarlyPerfInliner on the
/// deinit of a generic NSHostingView subclass in Release builds.
private final class ClickThroughHostingView: NSHostingView<ScreenRecordingSettingsGuideView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class GuidePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
