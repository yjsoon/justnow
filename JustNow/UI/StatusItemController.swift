import AppKit
import Foundation

enum StatusMenuItemTag: Int {
    case frameCount = 100
    case captureStatus = 101
    case pauseToggle = 102
    case permissionHelp = 103
    case showTimeline = 104
}

struct StatusItemControllerActions {
    let showTimeline: () -> Void
    let toggleCapturePause: () -> Void
    let showSettings: () -> Void
    let checkForUpdates: () -> Void
    let quitApp: () -> Void
    let showScreenRecordingHelp: () -> Void
    let menuWillOpen: () -> Void
}

private final class StatusMenuActionItemView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let accessoryImageView = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            needsDisplay = true
            updateAppearance()
        }
    }

    weak var menuItem: NSMenuItem?

    override var isFlipped: Bool { true }

    init(width: CGFloat = 220) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, accessorySystemImageName: String) {
        titleField.stringValue = title
        accessoryImageView.image = NSImage(
            systemSymbolName: accessorySystemImageName,
            accessibilityDescription: title
        )
        accessoryImageView.image?.isTemplate = true
        updateAppearance()
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        // Menu keyboard navigation updates `enclosingMenuItem.isHighlighted` without toggling hover;
        // refresh label and symbol colours whenever AppKit is about to draw this row.
        updateAppearance()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if isHovered || enclosingMenuItem?.isHighlighted == true {
            NSColor.selectedContentBackgroundColor.setFill()
            dirtyRect.fill()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // If the menu dismisses while the pointer is still over this row, AppKit may not send mouseExited.
        if newWindow == nil {
            isHovered = false
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location),
              let menuItem,
              let action = menuItem.action else {
            return
        }

        isHovered = false
        let target = menuItem.target ?? NSApp.target(forAction: action, to: nil, from: menuItem)
        menuItem.menu?.cancelTracking()
        NSApp.sendAction(action, to: target, from: menuItem)
    }

    private func setup() {
        titleField.lineBreakMode = .byTruncatingTail
        titleField.font = .menuFont(ofSize: 0)

        accessoryImageView.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        accessoryImageView.imageScaling = .scaleProportionallyDown

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stackView = NSStackView(views: [titleField, spacer, accessoryImageView])
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.distribution = .fill
        stackView.spacing = 8
        stackView.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)

        addSubview(stackView)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            accessoryImageView.widthAnchor.constraint(equalToConstant: 14)
        ])

        titleField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        accessoryImageView.setContentHuggingPriority(.required, for: .horizontal)
        accessoryImageView.setContentCompressionResistancePriority(.required, for: .horizontal)

        updateAppearance()
    }

    private func updateAppearance() {
        let isHighlighted = isHovered || enclosingMenuItem?.isHighlighted == true
        titleField.textColor = isHighlighted ? .selectedMenuItemTextColor : .labelColor
        accessoryImageView.contentTintColor = isHighlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
    }
}

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu: NSMenu

    private let statusBar: NSStatusBar
    private let actions: StatusItemControllerActions

    private let showTimelineItem: NSMenuItem
    private let pauseItem: NSMenuItem
    private let frameCountItem: NSMenuItem
    private let captureStatusItem: NSMenuItem
    private let permissionHelpItem: NSMenuItem

    init(
        actions: StatusItemControllerActions,
        statusBar: NSStatusBar = .system
    ) {
        self.actions = actions
        self.statusBar = statusBar
        self.statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        self.menu = NSMenu()

        showTimelineItem = NSMenuItem(title: "Show Timeline", action: nil, keyEquivalent: "")
        pauseItem = NSMenuItem(title: "Pause Recording", action: nil, keyEquivalent: "")
        frameCountItem = NSMenuItem(title: "Frames: 0", action: nil, keyEquivalent: "")
        captureStatusItem = NSMenuItem(title: "Capture: Starting...", action: nil, keyEquivalent: "")
        permissionHelpItem = NSMenuItem(title: "Screen Recording Help…", action: nil, keyEquivalent: "")

        super.init()
        setupMenu()
        updateStatusItemButtonAppearance(isPaused: false)
        setPaused(false)
        setFrameCount(0)
        setCaptureStatus("Starting...")
        setPermissionHelpVisible(false)
    }

    deinit {
        statusBar.removeStatusItem(statusItem)
    }

    func setFrameCount(_ count: Int) {
        frameCountItem.title = "Frames: \(count)"
    }

    func setCaptureStatus(_ status: String) {
        captureStatusItem.title = "Capture: \(status)"
    }

    func setPaused(_ isPaused: Bool) {
        pauseItem.title = isPaused ? "Resume Recording" : "Pause Recording"
        pauseItem.state = .off
        pauseItem.image = nil
        (pauseItem.view as? StatusMenuActionItemView)?.configure(
            title: pauseItem.title,
            accessorySystemImageName: isPaused ? "play.fill" : "pause.fill"
        )
        updateStatusItemButtonAppearance(isPaused: isPaused)
    }

    func setPermissionHelpVisible(_ isVisible: Bool) {
        permissionHelpItem.isHidden = !isVisible
        permissionHelpItem.isEnabled = isVisible
    }

    func item(for tag: StatusMenuItemTag) -> NSMenuItem? {
        menu.item(withTag: tag.rawValue)
    }

    func menuWillOpen(_ menu: NSMenu) {
        actions.menuWillOpen()
    }

    private func setupMenu() {
        showTimelineItem.target = self
        showTimelineItem.action = #selector(handleShowTimeline)
        showTimelineItem.tag = StatusMenuItemTag.showTimeline.rawValue
        showTimelineItem.keyEquivalentModifierMask = [.command, .option]
        showTimelineItem.view = makeMenuActionView(for: showTimelineItem)
        (showTimelineItem.view as? StatusMenuActionItemView)?.configure(
            title: showTimelineItem.title,
            accessorySystemImageName: "backward.fill"
        )
        menu.addItem(showTimelineItem)

        pauseItem.target = self
        pauseItem.action = #selector(handleToggleCapturePause)
        pauseItem.tag = StatusMenuItemTag.pauseToggle.rawValue
        pauseItem.view = makeMenuActionView(for: pauseItem)
        menu.addItem(pauseItem)

        menu.addItem(.separator())

        frameCountItem.tag = StatusMenuItemTag.frameCount.rawValue
        frameCountItem.isEnabled = false
        menu.addItem(frameCountItem)

        captureStatusItem.tag = StatusMenuItemTag.captureStatus.rawValue
        captureStatusItem.isEnabled = false
        menu.addItem(captureStatusItem)

        permissionHelpItem.target = self
        permissionHelpItem.action = #selector(handleShowScreenRecordingHelp)
        permissionHelpItem.tag = StatusMenuItemTag.permissionHelp.rawValue
        menu.addItem(permissionHelpItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(handleShowSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(handleCheckForUpdates), keyEquivalent: "")
        updatesItem.target = self
        menu.addItem(updatesItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit JustNow", action: #selector(handleQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    private func makeMenuActionView(for item: NSMenuItem) -> StatusMenuActionItemView {
        let view = StatusMenuActionItemView()
        view.menuItem = item
        return view
    }

    private func updateStatusItemButtonAppearance(isPaused: Bool) {
        guard let button = statusItem.button else { return }
        let accessibilityDescription = isPaused ? "JustNow (Paused)" : "JustNow"
        let assetName = isPaused ? "StatusBarIdle" : "StatusBarRecording"

        if let image = NSImage(named: assetName)?.copy() as? NSImage {
            image.isTemplate = true
            image.accessibilityDescription = accessibilityDescription
            button.image = image
        } else {
            button.image = NSImage(
                systemSymbolName: "clock.arrow.circlepath",
                accessibilityDescription: accessibilityDescription
            )
            button.image?.isTemplate = true
        }

        button.imagePosition = .imageOnly
        button.title = ""
    }

    @objc private func handleShowTimeline() {
        actions.showTimeline()
    }

    @objc private func handleToggleCapturePause() {
        actions.toggleCapturePause()
    }

    @objc private func handleShowSettings() {
        actions.showSettings()
    }

    @objc private func handleCheckForUpdates() {
        actions.checkForUpdates()
    }

    @objc private func handleQuit() {
        actions.quitApp()
    }

    @objc private func handleShowScreenRecordingHelp() {
        actions.showScreenRecordingHelp()
    }
}
