import AppKit
import SwiftUI

/// Dropdown that lives inside the overlay's "more" pill. Built on AppKit
/// (`NSMenu` + custom `NSMenuItem.view`) instead of SwiftUI's `Menu` so we can
/// render a bare `⌘` symbol in the shortcut column for "Save Region…".
/// `NSMenuItem` only paints its shortcut column when `keyEquivalent` is a real
/// key character — modifiers alone never render — so we draw the whole row
/// ourselves.
struct OverlayMoreMenuIsland: View {
    var viewModel: OverlayViewModel

    var body: some View {
        MoreMenuTrigger(viewModel: viewModel)
            .frame(width: 32, height: 32)
            .fixedSize()
            .darkBarBackground(in: Circle())
            .help("More actions")
            .accessibilityLabel("More actions")
            .accessibilityHint("Save the current screenshot, save a region, or open Settings.")
            .background(shortcutHosts)
    }

    /// Real shortcut bindings live here so ⌘S and ⌘, fire while the overlay is
    /// up — not just while the AppKit menu is open. The buttons are zero-sized
    /// and hit-test-disabled; they exist only to register the shortcuts with
    /// SwiftUI's responder chain.
    private var shortcutHosts: some View {
        ZStack {
            Button("") { viewModel.saveCurrentFrameToScreenshotsLocation() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!viewModel.canSaveCurrentFrame)
            Button("") { viewModel.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct MoreMenuTrigger: NSViewRepresentable {
    let viewModel: OverlayViewModel

    func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel) }

    func makeNSView(context: Context) -> NSButton {
        let button = TransparentButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.image = NSImage(
            systemSymbolName: "ellipsis",
            accessibilityDescription: "More actions"
        )
        button.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        button.contentTintColor = NSColor.white.withAlphaComponent(0.75)
        button.imagePosition = .imageOnly
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.focusRingType = .none
        button.setButtonType(.momentaryChange)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.viewModel = viewModel
    }

    @MainActor
    final class Coordinator: NSObject {
        var viewModel: OverlayViewModel

        init(viewModel: OverlayViewModel) {
            self.viewModel = viewModel
        }

        @objc func showMenu(_ sender: NSButton) {
            let menu = makeMenu()
            // Anchor below the button regardless of the host view's flip state.
            let yBelow: CGFloat = sender.isFlipped ? sender.bounds.maxY + 4 : -4
            let location = NSPoint(x: sender.bounds.minX, y: yBelow)
            menu.popUp(positioning: nil, at: location, in: sender)
        }

        private func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false

            // \u{2009} = thin space, mimicking native NSMenuItem's gap
            // between modifier glyph and key character.
            menu.addItem(makeRow(
                title: "Save Screenshot",
                systemImageName: "square.and.arrow.down",
                shortcut: "\u{2318}\u{2009}S",
                isEnabled: viewModel.canSaveCurrentFrame,
                action: #selector(handleSaveScreenshot)
            ))

            menu.addItem(makeRow(
                title: "Save Region…",
                systemImageName: "rectangle.dashed",
                shortcut: "\u{2318}",
                isEnabled: viewModel.canSaveCurrentFrame,
                action: #selector(handleSaveRegion)
            ))

            menu.addItem(.separator())

            menu.addItem(makeRow(
                title: "Open Settings…",
                systemImageName: "gearshape",
                shortcut: "\u{2318}\u{2009},",
                isEnabled: true,
                action: #selector(handleOpenSettings)
            ))

            return menu
        }

        private func makeRow(
            title: String,
            systemImageName: String,
            shortcut: String,
            isEnabled: Bool,
            action: Selector
        ) -> NSMenuItem {
            // No keyEquivalent: real shortcuts are owned by the hidden SwiftUI
            // buttons in OverlayMoreMenuIsland.shortcutHosts. Setting it here
            // would either double-fire (with the SwiftUI button) or only work
            // while the menu is open.
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = isEnabled

            let row = MoreMenuItemRowView()
            row.menuItem = item
            row.isEnabled = isEnabled
            row.configure(title: title, systemImageName: systemImageName, shortcut: shortcut)
            item.view = row

            return item
        }

        @objc private func handleSaveScreenshot() {
            viewModel.saveCurrentFrameToScreenshotsLocation()
        }

        @objc private func handleSaveRegion() {
            viewModel.armRegionScreenshot()
        }

        @objc private func handleOpenSettings() {
            viewModel.openSettings()
        }
    }
}

private final class TransparentButton: NSButton {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // The SwiftUI .darkBarBackground modifier provides the dark circular
        // pill underneath; keep the button itself transparent so press/hover
        // states don't paint a second background on top.
        layer?.backgroundColor = .clear
    }
}

private final class MoreMenuItemRowView: NSView {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let shortcutField = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?

    weak var menuItem: NSMenuItem?

    var isEnabled: Bool = true {
        didSet {
            updateAppearance()
            needsDisplay = true
        }
    }

    private var isHovered = false {
        didSet {
            needsDisplay = true
            updateAppearance()
        }
    }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        // NSMenu sizes rows to the widest item; width autoresizing keeps the
        // hover background painting across the full row.
        autoresizingMask = [.width]
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, systemImageName: String, shortcut: String) {
        titleField.stringValue = title
        let image = NSImage(systemSymbolName: systemImageName, accessibilityDescription: title)
        image?.isTemplate = true
        iconView.image = image
        shortcutField.stringValue = shortcut
        updateAppearance()
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        // Keyboard navigation toggles enclosingMenuItem.isHighlighted without
        // sending mouseEntered, so refresh colours on every draw.
        updateAppearance()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isEnabled, isHovered || enclosingMenuItem?.isHighlighted == true else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        bounds.fill()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { isHovered = false }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard isEnabled,
              bounds.contains(location),
              let menuItem,
              let action = menuItem.action else { return }
        isHovered = false
        let target = menuItem.target ?? NSApp.target(forAction: action, to: nil, from: menuItem)
        menuItem.menu?.cancelTracking()
        NSApp.sendAction(action, to: target, from: menuItem)
    }

    private func setup() {
        titleField.lineBreakMode = .byTruncatingTail
        titleField.font = .menuFont(ofSize: 0)
        titleField.isBezeled = false
        titleField.drawsBackground = false
        titleField.isEditable = false
        titleField.isSelectable = false

        iconView.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        iconView.imageScaling = .scaleProportionallyDown

        shortcutField.font = .menuFont(ofSize: 0)
        shortcutField.alignment = .right
        shortcutField.isBezeled = false
        shortcutField.drawsBackground = false
        shortcutField.isEditable = false
        shortcutField.isSelectable = false

        // Direct anchors instead of NSStackView: the shortcut field must pin
        // to the trailing edge so a bare ⌘ (narrower than ⌘ S) still lands in
        // the right-hand shortcut column.
        addSubview(iconView)
        addSubview(titleField)
        addSubview(shortcutField)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleField.translatesAutoresizingMaskIntoConstraints = false
        shortcutField.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),

            shortcutField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            shortcutField.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutField.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleField.trailingAnchor,
                constant: 12
            ),
        ])

        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shortcutField.setContentHuggingPriority(.required, for: .horizontal)
        shortcutField.setContentCompressionResistancePriority(.required, for: .horizontal)

        updateAppearance()
    }

    override var intrinsicContentSize: NSSize {
        // NSMenu sizes rows to the widest item's intrinsic content size.
        // Force a generous shortcut column so all rows share the same column
        // even when one row only has a bare ⌘.
        NSSize(width: 240, height: 22)
    }

    private func updateAppearance() {
        let highlighted = isEnabled && (isHovered || enclosingMenuItem?.isHighlighted == true)

        let primary: NSColor
        let secondary: NSColor
        if !isEnabled {
            primary = .disabledControlTextColor
            secondary = .disabledControlTextColor
        } else if highlighted {
            primary = .selectedMenuItemTextColor
            secondary = .selectedMenuItemTextColor
        } else {
            primary = .labelColor
            secondary = .secondaryLabelColor
        }

        titleField.textColor = primary
        iconView.contentTintColor = secondary
        shortcutField.textColor = secondary
    }
}
