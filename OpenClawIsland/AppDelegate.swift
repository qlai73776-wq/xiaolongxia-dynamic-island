import AppKit

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTouchBarDelegate {
    private let viewModel = IslandViewModel()
    private var panel: FloatingPanel?
    private var islandView: DynamicIslandView?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var trackingIslandGesture = false
    private var gestureStartPoint: NSPoint = .zero
    private var gestureStartTime: TimeInterval = 0
    private var scrollAccumulatorX: CGFloat = 0
    private var scrollGestureConsumed = false
    private var scrollResetWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createPanel()
        installMouseMonitors()
        viewModel.onChange = { [weak self] in
            self?.updatePanelVisibilityAndLayout()
        }
        updatePanelVisibilityAndLayout()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { viewModel.updateState(fromURL: $0) }
    }

    func createPanel() {
        guard panel == nil else { return }
        guard let screen = NSScreen.main else {
            fputs("OpenClawIsland: NSScreen.main unavailable\n", stderr)
            return
        }
        let size = DynamicIslandView.compactSize
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.maxY - size.height - 34

        let panel = FloatingPanel(
            contentRect: NSRect(origin: CGPoint(x: x, y: y), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar + 2
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        let islandView = DynamicIslandView(viewModel: viewModel)
        panel.contentView = islandView
        self.islandView = islandView

        if #available(macOS 10.12.2, *) {
            panel.touchBar = makeTouchBar()
        }

        panel.orderOut(nil)
        self.panel = panel
        fputs("OpenClawIsland: panel created at \(panel.frame)\n", stderr)
    }

    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved, .scrollWheel]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            _ = self?.handleIslandMouseEvent(event)
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            return self.handleIslandMouseEvent(event) ? nil : event
        }
    }

    private func handleIslandMouseEvent(_ event: NSEvent) -> Bool {
        guard let panel, viewModel.shouldShowIsland else { return false }
        let point = NSEvent.mouseLocation
        let hitFrame = panel.frame.insetBy(dx: -12, dy: -12)
        let isInside = hitFrame.contains(point)

        switch event.type {
        case .mouseMoved:
            viewModel.setPointerInside(isInside)
            return false
        case .scrollWheel:
            guard isInside else {
                scrollAccumulatorX = 0
                return false
            }
            handleHorizontalScroll(event)
            return true
        case .leftMouseDown:
            guard isInside else { return false }
            trackingIslandGesture = true
            gestureStartPoint = point
            gestureStartTime = event.timestamp
            return true
        case .leftMouseDragged:
            return trackingIslandGesture
        case .leftMouseUp:
            guard trackingIslandGesture else { return false }
            trackingIslandGesture = false

            let dx = point.x - gestureStartPoint.x
            let duration = event.timestamp - gestureStartTime
            if abs(dx) > 22 {
                viewModel.selectNextAgent(direction: dx < 0 ? 1 : -1)
            } else if duration > 0.55 {
                viewModel.simulateWeatherFlow()
            }
            return true
        default:
            return false
        }
    }

    private func handleHorizontalScroll(_ event: NSEvent) {
        let horizontal = event.scrollingDeltaX
        guard abs(horizontal) > abs(event.scrollingDeltaY), abs(horizontal) > 0.5 else { return }

        guard !scrollGestureConsumed else { return }
        scheduleScrollAccumulatorReset()

        scrollAccumulatorX += horizontal
        guard abs(scrollAccumulatorX) >= 42 else { return }

        viewModel.selectNextAgent(direction: scrollAccumulatorX < 0 ? 1 : -1)
        scrollGestureConsumed = true
        scrollAccumulatorX = 0
        scheduleScrollGestureUnlock()
    }

    private func scheduleScrollAccumulatorReset() {
        scrollResetWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.scrollAccumulatorX = 0
        }
        scrollResetWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: item)
    }

    private func scheduleScrollGestureUnlock() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.70) { [weak self] in
            self?.scrollGestureConsumed = false
        }
    }

    private func updatePanelVisibilityAndLayout() {
        guard let panel, let islandView, let screen = NSScreen.main else { return }
        guard viewModel.shouldShowIsland else {
            panel.orderOut(nil)
            return
        }

        let size = viewModel.isExpanded ? DynamicIslandView.expandedSize : DynamicIslandView.compactSize
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.maxY - size.height - 34
        panel.setFrame(NSRect(origin: CGPoint(x: x, y: y), size: size), display: true, animate: true)
        islandView.setFrameSize(size)
        islandView.needsDisplay = true
        panel.orderFrontRegardless()
    }

    @available(macOS 10.12.2, *)
    private func makeTouchBar() -> NSTouchBar {
        let touchBar = NSTouchBar()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = viewModel.agents.map { NSTouchBarItem.Identifier("agent.\($0.id)") }
        return touchBar
    }

    @available(macOS 10.12.2, *)
    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let raw = identifier.rawValue
        guard raw.hasPrefix("agent.") else { return nil }
        let id = String(raw.dropFirst("agent.".count))
        guard let agent = viewModel.agents.first(where: { $0.id == id }) else { return nil }

        let item = NSCustomTouchBarItem(identifier: identifier)
        let button = NSButton(title: "\(agent.avatar) \(agent.name)", target: self, action: #selector(selectTouchBarAgent(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(raw)
        item.view = button
        return item
    }

    @objc private func selectTouchBarAgent(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("agent.") else { return }
        viewModel.setAgent(id: String(raw.dropFirst("agent.".count)))
    }
}

@main
struct OpenClawIslandMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        delegate.createPanel()
        app.run()
    }
}
