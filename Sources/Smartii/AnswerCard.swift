import Cocoa

// MARK: - AnswerSink

/// The surface a solve streams its answer into. Both the chat panel
/// (`BarController`) and the compact corner card adopt it, so `AppDelegate.runSolve`
/// can target either without caring which one is on screen.
@MainActor
protocol AnswerSink: AnyObject {
    func setThinking(_ on: Bool)
    func beginStreaming()
    func appendDelta(_ s: String)
    func endStreaming()
    func showAnswer(_ text: String)
    func showError(_ message: String)
}

// MARK: - CardView

/// The card's frosted background. Any click outside the close button dismisses
/// the card; scroll-wheel events are forwarded to the answer's scroll view so long
/// answers can still be scrolled.
private final class CardView: NSVisualEffectView {
    var onClick: (() -> Void)?
    var closeButton: NSView?
    var scrollTarget: NSScrollView?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if let closeButton, hit.isDescendant(of: closeButton) { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func scrollWheel(with event: NSEvent) {
        scrollTarget?.scrollWheel(with: event)
    }
}

// MARK: - AnswerCardController

/// A small, non-activating floating card pinned to the bottom-right corner of the
/// screen under the mouse. It stays hidden while the model is working and appears
/// once, fully formed, with the finished answer — no thinking indicator and no
/// streaming growth, so nothing moves in the corner until there is something to
/// read. It shows only the latest answer, never takes keyboard focus away from the
/// frontmost app, and is dismissed by clicking it, its ×, or the panic hotkey.
@MainActor
final class AnswerCardController: NSObject, AnswerSink {

    private enum C {
        static let width: CGFloat = 340
        static let inset: CGFloat = 14
        static let headerHeight: CGFloat = 16
        static let gap: CGFloat = 8
        static let minTextHeight: CGFloat = 12
        static let maxTextHeight: CGFloat = 300
        static let screenMargin: CGFloat = 16
        static let corner: CGFloat = 14
        static let fontSize: CGFloat = 13
        static let error = NSColor(calibratedRed: 0xff / 255.0, green: 0x7a / 255.0, blue: 0x8a / 255.0, alpha: 1)
        static var contentWidth: CGFloat { width - inset * 2 }
    }

    private let panel: NSPanel
    private let card = CardView()
    private let titleLabel = NSTextField(labelWithString: "✦ Smartii")
    private let closeButton = NSButton()
    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private var textHeightConstraint: NSLayoutConstraint!

    /// Raw markdown accumulated for the in-flight answer. Rendered only when the
    /// stream finishes.
    private var raw = ""

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: C.width, height: 80),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        buildContent()
    }

    // MARK: Chrome

    private func configurePanel() {
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Same frosted glass as the chat panel: a behind-window blur that takes on
        // the colour of whatever is underneath, so the card blends into the page.
        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.isEmphasized = true
        card.wantsLayer = true
        if let layer = card.layer {
            layer.cornerRadius = C.corner
            layer.masksToBounds = true
            layer.borderWidth = 1
            layer.borderColor = Palette.border.cgColor
        }
        card.onClick = { [weak self] in self?.hide() }
        card.closeButton = closeButton
        card.scrollTarget = scroll
        panel.contentView = card
    }

    private func buildContent() {
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = Palette.secondary
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        closeButton.contentTintColor = Palette.secondary
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.toolTip = "Dismiss"
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        // Answer text: read-only, transparent, wraps at the card width.
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.frame = NSRect(x: 0, y: 0, width: C.contentWidth, height: 10)
        textView.textContainer?.containerSize = NSSize(width: C.contentWidth, height: .greatestFiniteMagnitude)

        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(titleLabel)
        card.addSubview(closeButton)
        card.addSubview(scroll)

        textHeightConstraint = scroll.heightAnchor.constraint(equalToConstant: C.minTextHeight)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: C.inset),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: C.inset),
            titleLabel.heightAnchor.constraint(equalToConstant: C.headerHeight),

            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -C.inset + 2),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),

            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: C.gap),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: C.inset),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -C.inset),
            textHeightConstraint,
        ])
    }

    // MARK: AnswerSink
    //
    // Nothing is shown until the answer is complete: a new request hides any
    // previous card, deltas only accumulate, and the card appears once at the end.

    func setThinking(_ on: Bool) {
        if on {
            raw = ""
            hide()
        }
    }

    func beginStreaming() {
        raw = ""
    }

    func appendDelta(_ s: String) {
        raw += s
    }

    func endStreaming() {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        render()
        scrollToTop()
        show()
    }

    func showAnswer(_ text: String) {
        raw = text
        render()
        scrollToTop()
        show()
    }

    func showError(_ message: String) {
        raw = ""
        let attr = NSAttributedString(string: "⚠︎ \(message)", attributes: [
            .foregroundColor: C.error,
            .font: NSFont.systemFont(ofSize: C.fontSize),
        ])
        apply(attr)
        scrollToTop()
        show()
    }

    // MARK: Show / hide

    func hide() {
        panel.orderOut(nil)
    }

    /// Fade the fully laid-out card in at its corner position.
    private func show() {
        panel.alphaValue = 0
        position(height: panel.frame.height)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    @objc private func closeTapped() { hide() }

    // MARK: Rendering

    /// Render `raw` as styled text. Markdown runs use the app's renderer; fenced
    /// code blocks are set in monospace on a subtle field-coloured background.
    private func render() {
        let out = NSMutableAttributedString()
        for (index, segment) in Markdown.splitFences(raw).enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n\n")) }
            switch segment.kind {
            case .markdown:
                out.append(Markdown.attributed(segment.text, textColor: Palette.text, baseSize: C.fontSize))
            case .code:
                out.append(NSAttributedString(string: segment.text, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: C.fontSize - 1, weight: .regular),
                    .foregroundColor: Palette.text,
                    .backgroundColor: Palette.field,
                ]))
            }
        }
        apply(out)
    }

    private func apply(_ attr: NSAttributedString) {
        textView.textStorage?.setAttributedString(attr)
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        container.containerSize = NSSize(width: C.contentWidth, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        let height = min(max(ceil(used), C.minTextHeight), C.maxTextHeight)
        layout(textHeight: height)
    }

    private func scrollToTop() {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: Geometry

    /// Resize the card to fit `textHeight` and keep it anchored bottom-right.
    private func layout(textHeight: CGFloat) {
        textHeightConstraint.constant = textHeight
        let height = C.inset + C.headerHeight + C.gap + textHeight + C.inset
        position(height: height)
        card.layoutSubtreeIfNeeded()
    }

    private func position(height: CGFloat) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = NSSize(width: C.width, height: height)
        let origin = NSPoint(
            x: visible.maxX - C.screenMargin - size.width,
            y: visible.minY + C.screenMargin
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
