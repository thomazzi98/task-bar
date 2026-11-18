import AppKit
import SwiftUI
import TaskBarCore

/// Owns the menu bar icon and the popover window.
///
/// *When* the popover opens and closes is decided by `PopoverBehavior`, a pure state machine
/// in the core module. This class only feeds it real events (hover, clicks, focus changes)
/// and carries out the effects it returns.
@MainActor
final class StatusItemController: NSObject, NSWindowDelegate {
    static let panelSize = NSSize(width: 420, height: 600)
    private static let hoverOpenDelay: Duration = .milliseconds(160)
    private static let pointerSampleInterval: Duration = .milliseconds(200)

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = PopoverPanel(contentSize: StatusItemController.panelSize)
    private let appState: AppState
    private let settings: SettingsStore

    private var behavior = PopoverBehavior()
    private var hoverOpenTask: Task<Void, Never>?
    private var pointerSamplingTask: Task<Void, Never>?
    private var outsideClickMonitor: Any?
    /// Fallback hover detection, used only until the tracking area proves it works.
    private var hoverPollTimer: Timer?
    private var wasPointerOverIcon = false
    private var isTrackingAreaConfirmed = false

    var onVisibilityChange: ((Bool) -> Void)?
    /// Builds the menu shown on right-click.
    var contextMenuProvider: (() -> NSMenu)?

    var onEscape: (() -> Bool)? {
        get { panel.onEscape }
        set { panel.onEscape = newValue }
    }

    var onCommandKey: ((String) -> Bool)? {
        get { panel.onCommandKey }
        set { panel.onCommandKey = newValue }
    }

    init(appState: AppState, settings: SettingsStore, content: some View) {
        self.appState = appState
        self.settings = settings
        super.init()

        panel.setContent(content)
        panel.delegate = self
        configureButton()
        updateHoverPolling()
        observeHoverSetting()
    }

    var isVisible: Bool { behavior.isVisible }

    // MARK: Requests from the rest of the app

    /// Shows the popover and gives it keyboard focus.
    func show() {
        send(.openRequested)
    }

    func hide() {
        send(.dismissRequested)
    }

    /// The global shortcut: open if closed, close if open.
    func toggle() {
        send(.shortcutPressed)
    }

    // MARK: Behaviour plumbing

    private func send(_ event: PopoverBehavior.Event) {
        behavior.isPinned = appState.isPinned
        behavior.isHeldOpen = appState.holdOpenCount > 0
        behavior.opensOnHover = settings.opensOnHover

        switch behavior.handle(event) {
        case .show(let takingFocus):
            present(takingFocus: takingFocus)
        case .takeFocus:
            takeFocus()
        case .hide:
            dismiss()
        case nil:
            break
        }
    }

    private func present(takingFocus: Bool) {
        hoverOpenTask?.cancel()

        let target = targetFrame()
        panel.alphaValue = 0
        panel.setFrame(target.offsetBy(dx: 0, dy: 6), display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }

        appState.isPanelVisible = true
        onVisibilityChange?(true)
        installOutsideClickMonitor()
        setButtonHighlighted(true)

        if takingFocus {
            takeFocus()
        } else {
            startPointerSampling()
        }
    }

    private func takeFocus() {
        pointerSamplingTask?.cancel()
        panel.makeKey()
        appState.requestPrimaryFocus()
    }

    private func dismiss() {
        hoverOpenTask?.cancel()
        pointerSamplingTask?.cancel()
        removeOutsideClickMonitor()
        setButtonHighlighted(false)
        appState.isPanelVisible = false
        onVisibilityChange?(false)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                // It may have been reopened while fading out.
                guard let self, !self.behavior.isVisible else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    // MARK: Badge

    func updateBadge(_ badge: BadgeState) {
        guard let button = statusItem.button else { return }
        switch badge {
        case .none:
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("TaskBar")
        case .attention(let count):
            setBadge(count > 1 ? "\(count)" : "●", color: .systemOrange, isDot: count <= 1, on: button)
            button.setAccessibilityLabel("TaskBar, \(count) agent\(count == 1 ? "" : "s") waiting for you")
        case .finished(let count):
            setBadge("●", color: .systemGreen, isDot: true, on: button)
            button.setAccessibilityLabel("TaskBar, \(count) agent\(count == 1 ? "" : "s") finished")
        }
    }

    private func setBadge(_ text: String, color: NSColor, isDot: Bool, on button: NSStatusBarButton) {
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: isDot ? 8 : 11, weight: .bold),
            .baselineOffset: isDot ? 3 : 0.5
        ])
        button.imagePosition = .imageLeading
    }

    // MARK: Button setup

    private func configureButton() {
        guard let button = statusItem.button else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "TaskBar")?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel("TaskBar")

        let hover = HoverTrackingView(frame: button.bounds)
        hover.autoresizingMask = [.width, .height]
        hover.onEnter = { [weak self] in self?.trackingAreaEntered() }
        hover.onExit = { [weak self] in self?.hoverOpenTask?.cancel() }
        button.addSubview(hover)
    }

    @objc private func handleClick(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
        } else {
            Log.app.info("menu bar icon clicked")
            hoverOpenTask?.cancel()
            send(.iconClicked)
        }
    }

    private func showContextMenu() {
        guard let menu = contextMenuProvider?() else { return }
        hide()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func setButtonHighlighted(_ highlighted: Bool) {
        // Deferred: AppKit resets the highlight when the triggering mouse-up finishes.
        Task { @MainActor [weak self] in
            self?.statusItem.button?.highlight(highlighted)
        }
    }

    // MARK: Pointer tracking

    /// Hover is detected by a tracking area on the status button, which costs nothing while
    /// the pointer is elsewhere. Whether such an area receives events depends on how the
    /// system hosts menu bar items, so until it has fired once a slow timer also compares the
    /// pointer with the icon's frame. The first tracking event stops that timer for good.
    ///
    /// A global "mouse moved" monitor would be simpler, but it wakes the app for every pointer
    /// event on the system, which measured around 10% CPU while the mouse was moving.
    private func updateHoverPolling() {
        let needsPolling = settings.opensOnHover && !isTrackingAreaConfirmed
        if needsPolling, hoverPollTimer == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.pollPointer()
                }
            }
            // Tolerance lets the system batch this wake-up with others.
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            hoverPollTimer = timer
        } else if !needsPolling, let timer = hoverPollTimer {
            timer.invalidate()
            hoverPollTimer = nil
            wasPointerOverIcon = false
        }
    }

    private func observeHoverSetting() {
        withObservationTracking {
            _ = settings.opensOnHover
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateHoverPolling()
                self?.observeHoverSetting()
            }
        }
    }

    private func trackingAreaEntered() {
        if !isTrackingAreaConfirmed {
            isTrackingAreaConfirmed = true
            updateHoverPolling()
            Log.app.info("hover: tracking area works, fallback polling stopped")
        }
        pointerEnteredIcon(source: "tracking area")
    }

    private func pollPointer() {
        let isOverIcon = isPointerOverIcon
        guard isOverIcon != wasPointerOverIcon else { return }
        wasPointerOverIcon = isOverIcon
        if isOverIcon {
            pointerEnteredIcon(source: "polling")
        } else {
            hoverOpenTask?.cancel()
        }
    }

    private func pointerEnteredIcon(source: String) {
        guard settings.opensOnHover, !behavior.isVisible, NSEvent.pressedMouseButtons == 0 else { return }
        Log.app.info("pointer entered the menu bar icon (\(source, privacy: .public))")
        hoverOpenTask?.cancel()
        hoverOpenTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hoverOpenDelay)
            guard !Task.isCancelled, let self, NSEvent.pressedMouseButtons == 0 else { return }
            self.send(.hoverDelayElapsed(pointerOverIcon: self.isPointerOverIcon))
        }
    }

    /// Samples the pointer only while a popover is open but untouched. Once the user
    /// interacts with it, or it closes, the loop ends and nothing is polled.
    private func startPointerSampling() {
        pointerSamplingTask?.cancel()
        pointerSamplingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pointerSampleInterval)
                guard !Task.isCancelled, let self, self.behavior.needsPointerSampling else { return }
                // A drag in progress (for example reordering tasks) counts as being inside.
                let isInside = self.isPointerInsideHoverRegion || NSEvent.pressedMouseButtons != 0
                self.send(.pointerSampled(isInsideHoverRegion: isInside))
            }
        }
    }

    private var iconFrame: NSRect {
        guard let button = statusItem.button, let window = button.window else { return .zero }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private var isPointerOverIcon: Bool {
        iconFrame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    /// The icon, the popover, and the strip between them.
    private var isPointerInsideHoverRegion: Bool {
        let location = NSEvent.mouseLocation
        let icon = iconFrame
        let bridge = NSRect(
            x: icon.minX,
            y: panel.frame.maxY,
            width: icon.width,
            height: max(icon.maxY - panel.frame.maxY, 1)
        )
        return panel.frame.insetBy(dx: -6, dy: -6).contains(location)
            || bridge.insetBy(dx: -8, dy: -2).contains(location)
    }

    // MARK: Focus and outside clicks

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            // Global monitors are delivered on the main thread.
            MainActor.assumeIsolated {
                self?.send(.clickedOutside)
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        pointerSamplingTask?.cancel()
        send(.becameKey)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Wait one turn of the run loop: the click that took focus away may be on our own
        // icon, and its handler should see the popover still open.
        Task { @MainActor [weak self] in
            guard let self, !self.panel.isKeyWindow else { return }
            self.send(.resignedKey(pointerOverIcon: self.isPointerOverIcon))
        }
    }

    // MARK: Geometry

    private func targetFrame() -> NSRect {
        let icon = iconFrame
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: Self.panelSize)

        var size = Self.panelSize
        size.height = min(size.height, visible.height - 16)
        let margin: CGFloat = 8
        let idealX = icon.midX - size.width / 2
        let x = min(max(idealX, visible.minX + margin), visible.maxX - size.width - margin)
        let top = icon == .zero ? visible.maxY : min(icon.minY, visible.maxY)
        return NSRect(x: x, y: top - size.height - 5, width: size.width, height: size.height)
    }
}

/// An invisible view over the status button that reports pointer entry and exit while letting
/// clicks fall through to the button.
private final class HoverTrackingView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        onEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        onExit?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
