import AppKit

/// One highlighted word on screen.
struct OverlayMark {
    var id: Int        // index of the match it shows
    var rect: CGRect   // AX coordinates
    var color: NSColor
    var wavy: Bool
    var strength: CGFloat   // 0–1, see Highlights.strength
}

/// A transparent, click-through window laid exactly over the host editor's scroll area (SPEC §5.2).
/// Being the size of the visible text area, it clips highlights on partly scrolled-off lines for free.
@MainActor
final class OverlayWindow {
    private let window: NSWindow
    private let view = OverlayView()

    init() {
        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        // Shown only while the host app is frontmost, so floating just above its windows is enough.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = view
    }

    var isVisible: Bool { window.isVisible }

    /// - Parameter clip: the visible editor area, in AX coordinates.
    func show(_ marks: [OverlayMark], clip: CGRect, background: Bool) {
        let frame = clip.flippedToCocoa
        if window.frame != frame { window.setFrame(frame, display: false) }
        view.origin = clip.origin
        view.marks = marks
        view.background = background
        view.needsDisplay = true
        if !window.isVisible { window.orderFrontRegardless() }
    }

    func hide() {
        if window.isVisible { window.orderOut(nil) }
        view.marks = []
    }

    /// The mark under an AX-coordinate point, with a little slack below for the underline.
    func mark(at point: CGPoint) -> OverlayMark? {
        guard window.isVisible else { return nil }
        return view.marks.first { $0.rect.insetBy(dx: 0, dy: -2).contains(point) }
    }

    /// Briefly outlines a word (AX coordinates), e.g. the other half of a repeat.
    func flash(_ rect: CGRect) {
        view.flash = rect
        view.needsDisplay = true
        Task { [weak view] in
            try? await Task.sleep(for: .seconds(1.2))
            view?.flash = nil
            view?.needsDisplay = true
        }
    }
}

private final class OverlayView: NSView {
    var marks: [OverlayMark] = []
    var origin = CGPoint.zero
    var background = false
    var flash: CGRect?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if let flash {
            let r = flash.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: -3, dy: -1)
            Highlights.repeatColor.withAlphaComponent(0.3).setFill()
            Highlights.repeatColor.setStroke()
            let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            path.lineWidth = 2
            path.fill()
            path.stroke()
        }
        for mark in marks {
            let r = mark.rect.offsetBy(dx: -origin.x, dy: -origin.y)
            guard r.intersects(bounds) else { continue }
            if background {
                mark.color.withAlphaComponent(0.1 + 0.25 * mark.strength).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: 0), xRadius: 2, yRadius: 2).fill()
                continue
            }
            if mark.wavy, mark.strength >= 0.85 {
                // Uncommon and rare repeats also get a soft tint: they're the ones readers notice.
                mark.color.withAlphaComponent(0.18 * mark.strength).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: 0), xRadius: 2, yRadius: 2).fill()
            }
            mark.color.withAlphaComponent(0.25 + 0.75 * mark.strength).setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1 + 1.2 * mark.strength
            path.lineCapStyle = .round
            // Line boxes include leading below the glyphs, so the underline sits a little above the bottom.
            let y = r.maxY - max(1.5, r.height * 0.12)
            if mark.wavy {
                let step: CGFloat = 2.5
                path.move(to: CGPoint(x: r.minX, y: y))
                var x = r.minX
                var up = true
                while x < r.maxX {
                    let next = min(x + step, r.maxX)
                    path.line(to: CGPoint(x: next, y: y + (up ? -1.5 : 1.5)))
                    x = next
                    up.toggle()
                }
            } else {
                path.move(to: CGPoint(x: r.minX, y: y))
                path.line(to: CGPoint(x: r.maxX, y: y))
            }
            path.stroke()
        }
    }
}

struct HoverAction {
    let title: String
    let help: String
    let perform: () -> Void
}

/// The bubble shown when the pointer rests on a highlight (SPEC §5.3): why it's flagged, plus actions.
/// A non-activating panel, so clicking its buttons leaves the writing app in front.
@MainActor
final class HoverBubble {
    private let panel: NSPanel
    private let label = NSTextField(wrappingLabelWithString: "")
    private let buttons = NSStackView()
    /// The match the bubble is about.
    private(set) var markID: Int?
    private var anchor = CGRect.null

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let box = NSVisualEffectView()
        box.material = .popover
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.preferredMaxLayoutWidth = 340
        buttons.orientation = .horizontal
        buttons.spacing = 6
        let stack = NSStackView(views: [label, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
        ])
        panel.contentView = box
    }

    var isVisible: Bool { panel.isVisible }

    /// Shows the bubble for mark `id` just below `wordRect` (AX coordinates).
    func show(_ text: String, actions: [HoverAction], for id: Int, below wordRect: CGRect) {
        markID = id
        anchor = wordRect
        label.stringValue = text
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for action in actions {
            let button = BubbleButton(title: action.title) { [weak self] in
                self?.hide()
                action.perform()
            }
            button.toolTip = action.help
            buttons.addArrangedSubview(button)
        }
        buttons.isHidden = actions.isEmpty
        label.preferredMaxLayoutWidth = max(340, buttons.fittingSize.width)
        let size = panel.contentView!.fittingSize
        let word = wordRect.flippedToCocoa
        var origin = CGPoint(x: word.minX, y: word.minY - size.height - 3)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(word) }) {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            if origin.y < visible.minY { origin.y = word.maxY + 3 }
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    /// Whether the pointer (AX coordinates) is on the word or the bubble, or travelling between them.
    func keepsOpen(at point: CGPoint) -> Bool {
        guard panel.isVisible else { return false }
        let bubble = panel.frame.flippedToAX
        return anchor.union(bubble).insetBy(dx: -6, dy: -6).contains(point)
    }

    func hide() {
        markID = nil
        panel.orderOut(nil)
    }
}

/// Buttons in a panel that never becomes key must respond to the first click.
private final class BubbleButton: NSButton {
    private var onClick: (() -> Void)?

    convenience init(title: String, onClick: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        self.onClick = onClick
        bezelStyle = .push
        controlSize = .small
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        target = self
        action = #selector(clicked)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func clicked() { onClick?() }
}
