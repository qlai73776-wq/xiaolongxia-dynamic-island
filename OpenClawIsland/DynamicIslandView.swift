import AppKit

final class DynamicIslandView: NSView {
    static let compactSize = NSSize(width: 52, height: 38)
    static let expandedSize = NSSize(width: 318, height: 64)

    private let viewModel: IslandViewModel
    private var mouseDownPoint: NSPoint = .zero
    private var mouseDownTime: TimeInterval = 0
    private var hover = false

    init(viewModel: IslandViewModel) {
        self.viewModel = viewModel
        super.init(frame: NSRect(origin: .zero, size: Self.compactSize))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.clear.setFill()
        dirtyRect.fill()

        guard viewModel.shouldShowIsland else { return }
        drawIsland(for: viewModel.activeAgent)
    }

    private func drawIsland(for agent: Agent) {
        let expanded = viewModel.isExpanded
        let rect = bounds.insetBy(dx: expanded ? 0 : 2, dy: expanded ? 2 : 2)
        let radius = rect.height / 2
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        NSColor.black.withAlphaComponent(0.94).setFill()
        path.fill()
        agent.state.statusColor.withAlphaComponent(hover ? 0.72 : 0.42).setStroke()
        path.lineWidth = 1.2
        path.stroke()

        if expanded {
            drawExpanded(agent, in: rect)
        } else {
            drawCompact(agent, in: rect)
        }
    }

    private func drawCompact(_ agent: Agent, in rect: NSRect) {
        drawText(
            agent.state.emoji,
            in: rect.offsetBy(dx: 0, dy: -1),
            font: .systemFont(ofSize: 24),
            color: .white,
            alignment: .center
        )
    }

    private func drawExpanded(_ agent: Agent, in rect: NSRect) {
        let emojiRect = NSRect(x: rect.minX + 12, y: rect.midY - 18, width: 36, height: 36)
        agent.state.statusColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(ovalIn: emojiRect).fill()
        drawText(agent.state.emoji, in: emojiRect.offsetBy(dx: 0, dy: -1), font: .systemFont(ofSize: 24), color: .white, alignment: .center)

        let title = "\(agent.name) · \(agent.state.title)"
        drawText(title, in: NSRect(x: rect.minX + 58, y: rect.maxY - 25, width: rect.width - 76, height: 17), font: .boldSystemFont(ofSize: 12.5), color: .white, alignment: .left)
        drawText(agent.detail, in: NSRect(x: rect.minX + 58, y: rect.maxY - 45, width: rect.width - 76, height: 17), font: .systemFont(ofSize: 11.5), color: NSColor.white.withAlphaComponent(0.68), alignment: .left)

        if viewModel.agents.count > 1 {
            let index = viewModel.agents.firstIndex(where: { $0.id == agent.id }).map { $0 + 1 } ?? 1
            drawText("\(index)/\(viewModel.agents.count)", in: NSRect(x: rect.maxX - 42, y: rect.minY + 8, width: 28, height: 13), font: .systemFont(ofSize: 10), color: NSColor.white.withAlphaComponent(0.45), alignment: .right)
        }
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }

    override func mouseEntered(with event: NSEvent) {
        hover = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hover = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        mouseDownTime = event.timestamp
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - mouseDownPoint.x
        let duration = event.timestamp - mouseDownTime

        if abs(dx) > 22 {
            viewModel.selectNextAgent(direction: dx < 0 ? 1 : -1)
            return
        }

        if duration > 0.55 {
            viewModel.simulateWeatherFlow()
            return
        }

        viewModel.toggleExpandedByUser()
    }
}
