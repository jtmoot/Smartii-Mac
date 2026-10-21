import Cocoa
import QuartzCore

// MARK: - Palette

// Centralized dark-UI colors so every view stays consistent.
enum Palette {
    static let background = NSColor(calibratedRed: 0x0f / 255.0, green: 0x0f / 255.0, blue: 0x14 / 255.0, alpha: 1)
    static let panelFill  = NSColor(calibratedRed: 0x0f / 255.0, green: 0x0f / 255.0, blue: 0x14 / 255.0, alpha: 0.96)
    static let field      = NSColor(calibratedRed: 0x1a / 255.0, green: 0x1a / 255.0, blue: 0x22 / 255.0, alpha: 1)
    static let text       = NSColor(calibratedRed: 0xf5 / 255.0, green: 0xf5 / 255.0, blue: 0xf7 / 255.0, alpha: 1)
    static let secondary  = NSColor(calibratedWhite: 0.62, alpha: 1)
    static let accent     = NSColor(calibratedRed: 0x7c / 255.0, green: 0x5c / 255.0, blue: 0xff / 255.0, alpha: 1)
    static let pink       = NSColor(calibratedRed: 0xff / 255.0, green: 0x5e / 255.0, blue: 0x9c / 255.0, alpha: 1)
    static let border     = NSColor(calibratedWhite: 1, alpha: 0.08)
}

// MARK: - FloatingPanel

/// Borderless, non-activating floating panel. Overriding `canBecomeKey` lets the
/// text field inside it accept keyboard focus even though the app is an accessory.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - FlippedStackView

/// An NSStackView whose coordinate system is flipped so that content lays out
/// top→down. Used as the transcript's documentView so new bubbles append at the
/// bottom and the scroll view scrolls naturally from the top.
private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

// MARK: - InputTextField

/// A borderless single-line text field that routes its key commands back to the
/// BarController. Using a dedicated NSTextFieldDelegate keeps Return / Cmd+Return /
/// Esc working inside a borderless panel.
private final class InputTextField: NSTextField {
    /// Plain Return (send, no screenshot).
    var onReturn: (() -> Void)?
    /// Cmd+Return (send with screenshot).
    var onCommandReturn: (() -> Void)?
    /// Esc (hide the panel).
    var onEscape: (() -> Void)?
}

// MARK: - SmartiiLogo (reactive robot avatar)

/// A tiny, layer-drawn robot avatar shown in the top bar. It bobs gently while
/// idle and pulses / spins while the assistant is streaming. Drawn from the
/// SmartiiLogo bundle image when available, otherwise a vector-drawn fallback so
/// the avatar always renders (the contract mandates a "reactive robot avatar").
@MainActor
final class SmartiiLogo: NSView {

    private let imageLayer = CALayer()
    private var isStreaming = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.masksToBounds = false
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)

        imageLayer.contentsGravity = .resizeAspect
        imageLayer.contents = SmartiiLogo.logoImage()
        layer?.addSublayer(imageLayer)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22),
        ])

        startIdleBob()
    }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
        // Keep transform anchored at the layer's center for clean rotation/scale.
        layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer?.frame = bounds
        layer?.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// Loads the bundled SmartiiLogo image as a CGImage, or returns nil so the
    /// drawn fallback (a violet rounded square avatar) is used instead.
    private static func logoImage() -> CGImage? {
        let candidates: [NSImage?] = [
            NSImage(named: "SmartiiLogo"),
            Bundle.main.image(forResource: "SmartiiLogo"),
        ]
        guard let img = candidates.compactMap({ $0 }).first else { return nil }
        var rect = NSRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    // MARK: Idle animation

    /// A gentle vertical bob + subtle breathe used while the panel is idle.
    private func startIdleBob() {
        guard let layer else { return }
        layer.removeAnimation(forKey: "stream")

        let bob = CABasicAnimation(keyPath: "transform.translation.y")
        bob.fromValue = -1.2
        bob.toValue = 1.2
        bob.duration = 1.6
        bob.autoreverses = true
        bob.repeatCount = .infinity
        bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(bob, forKey: "idle")
    }

    /// While streaming, swap the bob for a livelier pulse (scale) + slow spin so
    /// the avatar visibly "thinks".
    private func startStreamingAnimation() {
        guard let layer else { return }
        layer.removeAnimation(forKey: "idle")

        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 0.86
        pulse.toValue = 1.12
        pulse.duration = 0.5
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = Double.pi * 2
        spin.duration = 3.0
        spin.repeatCount = .infinity

        let group = CAAnimationGroup()
        group.animations = [pulse, spin]
        group.duration = 3.0
        group.repeatCount = .infinity
        layer.add(group, forKey: "stream")
    }

    /// Tell the avatar whether the assistant is currently streaming.
    func setStreaming(_ streaming: Bool) {
        guard streaming != isStreaming else { return }
        isStreaming = streaming
        if streaming {
            startStreamingAnimation()
        } else {
            startIdleBob()
        }
    }
}

// MARK: - Markdown rendering

/// Renders a (very small) subset of Markdown — headings, bold, italics, inline
/// code, bullet/numbered lists, blockquotes, and links — into an attributed
/// string suitable for an assistant bubble. Fenced code blocks are handled
/// separately by the bubble builder (see `splitFences`).
private enum Markdown {

    /// Splits raw text into ordered segments: plain markdown runs and fenced code
    /// blocks (``` ... ```), preserving the language tag when present.
    struct Segment {
        enum Kind { case markdown, code }
        let kind: Kind
        let text: String
        let language: String?
    }

    static func splitFences(_ raw: String) -> [Segment] {
        var segments: [Segment] = []
        let lines = raw.components(separatedBy: "\n")
        var buffer: [String] = []
        var codeBuffer: [String] = []
        var inCode = false
        var codeLang: String?

        func flushMarkdown() {
            if !buffer.isEmpty {
                let joined = buffer.joined(separator: "\n")
                if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(Segment(kind: .markdown, text: joined, language: nil))
                }
                buffer.removeAll()
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    // Closing fence.
                    segments.append(Segment(
                        kind: .code,
                        text: codeBuffer.joined(separator: "\n"),
                        language: codeLang
                    ))
                    codeBuffer.removeAll()
                    codeLang = nil
                    inCode = false
                } else {
                    // Opening fence.
                    flushMarkdown()
                    let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeLang = lang.isEmpty ? nil : lang
                    inCode = true
                }
            } else if inCode {
                codeBuffer.append(line)
            } else {
                buffer.append(line)
            }
        }
        // Unterminated code fence: treat the remainder as code anyway.
        if inCode, !codeBuffer.isEmpty {
            segments.append(Segment(kind: .code, text: codeBuffer.joined(separator: "\n"), language: codeLang))
        }
        flushMarkdown()
        return segments
    }

    // MARK: Inline + block attributed rendering

    static func attributed(_ markdown: String, textColor: NSColor, baseSize: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let blocks = markdown.components(separatedBy: "\n")
        var firstBlock = true

        var i = 0
        while i < blocks.count {
            let line = blocks[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if !firstBlock {
                out.append(NSAttributedString(string: "\n"))
            }
            firstBlock = false

            if trimmed.hasPrefix("### ") {
                out.append(heading(String(trimmed.dropFirst(4)), size: baseSize + 1, color: textColor))
            } else if trimmed.hasPrefix("## ") {
                out.append(heading(String(trimmed.dropFirst(3)), size: baseSize + 3, color: textColor))
            } else if trimmed.hasPrefix("# ") {
                out.append(heading(String(trimmed.dropFirst(2)), size: baseSize + 5, color: textColor))
            } else if trimmed.hasPrefix("> ") {
                let quote = inline(String(trimmed.dropFirst(2)), color: Palette.secondary, size: baseSize)
                out.append(NSAttributedString(string: "  "))
                out.append(quote)
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                out.append(NSAttributedString(string: "  •  ", attributes: [
                    .foregroundColor: Palette.accent,
                    .font: NSFont.systemFont(ofSize: baseSize),
                ]))
                out.append(inline(String(trimmed.dropFirst(2)), color: textColor, size: baseSize))
            } else if let m = orderedListMarker(trimmed) {
                out.append(NSAttributedString(string: "  \(m.number).  ", attributes: [
                    .foregroundColor: Palette.accent,
                    .font: NSFont.systemFont(ofSize: baseSize, weight: .medium),
                ]))
                out.append(inline(m.rest, color: textColor, size: baseSize))
            } else {
                out.append(inline(line, color: textColor, size: baseSize))
            }
            i += 1
        }
        return out
    }

    private static func orderedListMarker(_ line: String) -> (number: Int, rest: String)? {
        // Matches "1. text" / "12. text".
        var digits = ""
        var idx = line.startIndex
        while idx < line.endIndex, line[idx].isNumber {
            digits.append(line[idx])
            idx = line.index(after: idx)
        }
        guard !digits.isEmpty, idx < line.endIndex, line[idx] == "." else { return nil }
        let afterDot = line.index(after: idx)
        guard afterDot <= line.endIndex else { return nil }
        let rest = String(line[afterDot...]).trimmingCharacters(in: .whitespaces)
        guard let n = Int(digits) else { return nil }
        return (n, rest)
    }

    private static func heading(_ text: String, size: CGFloat, color: NSColor) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 2
        return NSAttributedString(string: text.trimmingCharacters(in: .whitespaces), attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: color,
            .paragraphStyle: para,
        ])
    }

    /// Renders inline spans: **bold**, *italic*, `code`, and [text](url) links.
    private static func inline(_ text: String, color: NSColor, size: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: color,
        ]
        let chars = Array(text)
        var idx = 0
        var plain = ""

        func flushPlain() {
            if !plain.isEmpty {
                result.append(NSAttributedString(string: plain, attributes: base))
                plain = ""
            }
        }

        while idx < chars.count {
            let c = chars[idx]

            // Link: [label](url)
            if c == "[", let link = parseLink(chars, from: idx) {
                flushPlain()
                var attrs = base
                attrs[.foregroundColor] = Palette.accent
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                if let url = URL(string: link.url) {
                    attrs[.link] = url
                }
                result.append(NSAttributedString(string: link.label, attributes: attrs))
                idx = link.endIndex
                continue
            }

            // Inline code: `code`
            if c == "`" {
                if let close = findClose(chars, of: "`", from: idx + 1) {
                    flushPlain()
                    let code = String(chars[(idx + 1)..<close])
                    result.append(NSAttributedString(string: code, attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular),
                        .foregroundColor: Palette.pink,
                        .backgroundColor: NSColor(calibratedWhite: 1, alpha: 0.08),
                    ]))
                    idx = close + 1
                    continue
                }
            }

            // Bold: **text**
            if c == "*", idx + 1 < chars.count, chars[idx + 1] == "*" {
                if let close = findCloseDouble(chars, from: idx + 2) {
                    flushPlain()
                    let inner = String(chars[(idx + 2)..<close])
                    result.append(NSAttributedString(string: inner, attributes: [
                        .font: NSFont.systemFont(ofSize: size, weight: .bold),
                        .foregroundColor: color,
                    ]))
                    idx = close + 2
                    continue
                }
            }

            // Italic: *text*
            if c == "*" {
                if let close = findClose(chars, of: "*", from: idx + 1) {
                    flushPlain()
                    let inner = String(chars[(idx + 1)..<close])
                    let italicFont = NSFontManager.shared.convert(
                        NSFont.systemFont(ofSize: size), toHaveTrait: .italicFontMask)
                    result.append(NSAttributedString(string: inner, attributes: [
                        .font: italicFont,
                        .foregroundColor: color,
                    ]))
                    idx = close + 1
                    continue
                }
            }

            plain.append(c)
            idx += 1
        }
        flushPlain()
        return result
    }

    private static func findClose(_ chars: [Character], of ch: Character, from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == ch { return i }
            // Don't let bold "**" be consumed by an italic search.
            if ch == "*", chars[i] == "*" { return nil }
            i += 1
        }
        return nil
    }

    private static func findCloseDouble(_ chars: [Character], from start: Int) -> Int? {
        var i = start
        while i + 1 < chars.count {
            if chars[i] == "*", chars[i + 1] == "*" { return i }
            i += 1
        }
        return nil
    }

    private static func parseLink(_ chars: [Character], from start: Int) -> (label: String, url: String, endIndex: Int)? {
        // start points at '['
        guard let closeBracket = findClose(chars, of: "]", from: start + 1) else { return nil }
        guard closeBracket + 1 < chars.count, chars[closeBracket + 1] == "(" else { return nil }
        guard let closeParen = findClose(chars, of: ")", from: closeBracket + 2) else { return nil }
        let label = String(chars[(start + 1)..<closeBracket])
        let url = String(chars[(closeBracket + 2)..<closeParen])
        return (label, url, closeParen + 1)
    }
}

// MARK: - BarController

/// Owns the floating "ask bar" panel rendered as a ChatGPT-style chat window.
///
/// Two states:
///   • COLLAPSED — short panel showing only the input pill (first launch).
///   • EXPANDED  — grows UPWARD to reveal a scrollable transcript above the input.
///
/// The panel's BOTTOM edge stays fixed; only the height (and therefore the origin)
/// changes, so the input pill never jumps. When the user has moved/sized the panel
/// itself we persist & restore that frame instead.
@MainActor
final class BarController: NSObject, NSTextFieldDelegate {

    // MARK: Public API (callbacks wired up by AppDelegate — DO NOT change signatures)

    var onSubmit: ((_ text: String, _ includeScreenshot: Bool) -> Void)?
    var onGodmode: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    // New streaming + chat callbacks (per contract).
    /// User tapped Stop while streaming.
    var onStop: (() -> Void)?
    /// User cleared the chat (so AppDelegate can reset conversation memory).
    var onNewChat: (() -> Void)?
    /// User chose region capture.
    var onRegionSolve: (() -> Void)?

    // MARK: Layout constants

    private let panelWidth: CGFloat = 560
    private let edgeInset: CGFloat = 14          // input pill inset from panel edges
    private let pillHeight: CGFloat = 46
    private let collapsedHeight: CGFloat = 74    // input bar only (computed in applyState)
    private let topBarHeight: CGFloat = 26
    private let maxTranscriptHeight: CGFloat = 460
    private let maxPanelHeight: CGFloat = 560
    private let bottomGap: CGFloat = 90          // distance above the screen bottom

    // MARK: Panel + views

    private let panel: FloatingPanel
    private let effectView = NSVisualEffectView()

    // Top bar (visible only when expanded).
    private let topBar = NSView()
    private let avatar = SmartiiLogo()
    private let smartiiLabel = NSTextField(labelWithString: "Smartii")
    private let pinButton: NSButton

    // Transcript.
    private let transcriptScroll = NSScrollView()
    private let transcriptStack = FlippedStackView()

    // Empty-state (example prompt chips), shown when the transcript is empty.
    private let emptyState = NSView()

    // Input pill.
    private let inputPill = NSView()
    private let inputField = InputTextField()
    /// Mirror of the input field editor's text, updated on every keystroke, so a
    /// submit always sees the latest text regardless of commit/focus timing.
    private var liveText = ""
    private let providerChip = NSButton()
    private let sendButton: NSButton

    // MARK: State

    /// The bubble views currently in the transcript (excluding the thinking bubble).
    private var transcript: [NSView] = []
    /// True after the user has sent something but before an answer arrives. Prevents
    /// duplicating the user bubble when setThinking(true) fires for the same message.
    private var hasPendingUser = false
    /// The transient "thinking…" bubble, if shown.
    private var thinkingBubble: NSView?
    /// True once at least one message exists, i.e. the panel is in expanded state.
    private var isExpanded = false
    /// Set while a streaming bubble is live (between begin/endStreaming).
    private var isStreaming = false
    /// Accumulated raw markdown for the in-progress streaming assistant bubble.
    private var streamingRaw = ""
    /// The currently-streaming assistant bubble row (whose content we re-render).
    private var streamingRow: NSView?

    // Height constraint we animate to grow/shrink the transcript region.
    private var transcriptHeightConstraint: NSLayoutConstraint!
    // Top-bar height — collapsed to 0 when there are no messages so the idle
    // panel is just the input pill.
    private var topBarHeightConstraint: NSLayoutConstraint!

    override init() {
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: collapsedHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        pinButton = NSButton()
        sendButton = NSButton()
        super.init()
        configurePanel()
        buildContent()
        applyPinned()
        applyState(animated: false)
        observePanelMoves()
    }

    // MARK: Panel chrome

    private func configurePanel() {
        panel.level = Settings.shared.pinned ? .floating : .normal
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Frosted, rounded contentView — the signature ChatGPT companion look.
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.isEmphasized = true
        effectView.wantsLayer = true
        if let layer = effectView.layer {
            layer.cornerRadius = 18
            layer.masksToBounds = true
            layer.borderWidth = 1
            layer.borderColor = Palette.border.cgColor
        }
        panel.contentView = effectView
    }

    private func buildContent() {
        let content = effectView

        // --- Top bar (avatar + Smartii label + pin / new / settings / close) ---
        topBar.translatesAutoresizingMaskIntoConstraints = false

        smartiiLabel.font = .systemFont(ofSize: 12, weight: .medium)
        smartiiLabel.textColor = Palette.secondary
        smartiiLabel.translatesAutoresizingMaskIntoConstraints = false

        let topLeft = NSStackView(views: [avatar, smartiiLabel])
        topLeft.orientation = .horizontal
        topLeft.spacing = 7
        topLeft.alignment = .centerY
        topLeft.translatesAutoresizingMaskIntoConstraints = false

        configurePinButton()
        let newButton = makeIconButton(symbol: "plus", tint: Palette.secondary, action: #selector(newChatTapped))
        let gearButton = makeIconButton(symbol: "gearshape", tint: Palette.secondary, action: #selector(settingsTapped))
        let closeButton = makeIconButton(symbol: "xmark", tint: Palette.secondary, action: #selector(closeTapped))

        let topRight = NSStackView(views: [pinButton, newButton, gearButton, closeButton])
        topRight.orientation = .horizontal
        topRight.spacing = 4
        topRight.alignment = .centerY
        topRight.translatesAutoresizingMaskIntoConstraints = false

        topBar.addSubview(topLeft)
        topBar.addSubview(topRight)
        topBarHeightConstraint = topBar.heightAnchor.constraint(equalToConstant: topBarHeight)
        NSLayoutConstraint.activate([
            topLeft.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            topLeft.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            topRight.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            topRight.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            topBarHeightConstraint
        ])

        // --- Transcript: flipped vertical stack inside a scroll view ---
        transcriptStack.orientation = .vertical
        transcriptStack.alignment = .leading
        transcriptStack.spacing = 10
        transcriptStack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        transcriptStack.translatesAutoresizingMaskIntoConstraints = false

        transcriptScroll.documentView = transcriptStack
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.drawsBackground = false
        transcriptScroll.borderType = .noBorder
        transcriptScroll.automaticallyAdjustsContentInsets = false
        transcriptScroll.translatesAutoresizingMaskIntoConstraints = false

        // The stack tracks the scroll view's width so bubbles wrap correctly.
        NSLayoutConstraint.activate([
            transcriptStack.leadingAnchor.constraint(equalTo: transcriptScroll.contentView.leadingAnchor),
            transcriptStack.trailingAnchor.constraint(equalTo: transcriptScroll.contentView.trailingAnchor),
            transcriptStack.topAnchor.constraint(equalTo: transcriptScroll.contentView.topAnchor),
            transcriptStack.widthAnchor.constraint(equalTo: transcriptScroll.widthAnchor)
        ])

        buildEmptyState()

        // --- Input pill ---
        inputPill.wantsLayer = true
        inputPill.layer?.backgroundColor = Palette.field.cgColor
        inputPill.layer?.cornerRadius = 12
        inputPill.translatesAutoresizingMaskIntoConstraints = false

        let cameraButton = makeIconButton(symbol: "camera.viewfinder", tint: Palette.secondary, action: #selector(cameraTapped))
        cameraButton.toolTip = "Capture screen (right-click for region)"
        // Right-clicking the camera offers full-screen vs region capture.
        let captureMenu = NSMenu()
        let fullItem = NSMenuItem(title: "Ask about full screen", action: #selector(cameraTapped), keyEquivalent: "")
        fullItem.target = self
        let regionItem = NSMenuItem(title: "Solve region…", action: #selector(regionCaptureTapped), keyEquivalent: "")
        regionItem.target = self
        captureMenu.addItem(fullItem)
        captureMenu.addItem(regionItem)
        cameraButton.menu = captureMenu

        let boltButton = makeIconButton(symbol: "bolt.fill", tint: Palette.secondary, action: #selector(godmodeTapped))
        boltButton.toolTip = "Godmode (solve what's on screen)"

        configureProviderChip()

        inputField.placeholderString = "Ask anything…"
        inputField.font = .systemFont(ofSize: 15)
        inputField.textColor = Palette.text
        inputField.drawsBackground = false
        inputField.backgroundColor = .clear
        inputField.isBezeled = false
        inputField.isBordered = false
        inputField.focusRingType = .none
        inputField.delegate = self
        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        inputField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let cell = inputField.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
            cell.wraps = false
            cell.isScrollable = true
        }
        // Key handling for the borderless panel.
        inputField.onReturn = { [weak self] in self?.submitFromField(includeScreenshot: false) }
        inputField.onCommandReturn = { [weak self] in self?.submitFromField(includeScreenshot: true) }
        inputField.onEscape = { [weak self] in self?.hidePanel() }

        // Circular accent send/stop button.
        configureSendButton()

        let pillRow = NSStackView(views: [cameraButton, boltButton, providerChip, inputField, sendButton])
        pillRow.orientation = .horizontal
        pillRow.spacing = 9
        pillRow.alignment = .centerY
        pillRow.translatesAutoresizingMaskIntoConstraints = false
        inputPill.addSubview(pillRow)
        NSLayoutConstraint.activate([
            pillRow.leadingAnchor.constraint(equalTo: inputPill.leadingAnchor, constant: 12),
            pillRow.trailingAnchor.constraint(equalTo: inputPill.trailingAnchor, constant: -8),
            pillRow.centerYAnchor.constraint(equalTo: inputPill.centerYAnchor),
            inputPill.heightAnchor.constraint(equalToConstant: pillHeight)
        ])

        // --- Assemble: top bar, transcript, input pill stacked vertically ---
        content.addSubview(topBar)
        content.addSubview(transcriptScroll)
        content.addSubview(emptyState)
        content.addSubview(inputPill)

        transcriptHeightConstraint = transcriptScroll.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: panelWidth),

            // Top bar pinned to the top.
            topBar.topAnchor.constraint(equalTo: content.topAnchor, constant: edgeInset),
            topBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: edgeInset + 2),
            topBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -(edgeInset + 2)),

            // Transcript fills the middle.
            transcriptScroll.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6),
            transcriptScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: edgeInset),
            transcriptScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -edgeInset),
            transcriptHeightConstraint,

            // Empty-state overlays the transcript region.
            emptyState.topAnchor.constraint(equalTo: transcriptScroll.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: transcriptScroll.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: transcriptScroll.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: transcriptScroll.trailingAnchor),

            // Input pill pinned to the bottom.
            inputPill.topAnchor.constraint(equalTo: transcriptScroll.bottomAnchor, constant: 6),
            inputPill.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: edgeInset),
            inputPill.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -edgeInset),
            inputPill.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -edgeInset)
        ])
    }

    // MARK: Empty-state chips

    private func buildEmptyState() {
        emptyState.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Try one of these")
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = Palette.secondary
        title.translatesAutoresizingMaskIntoConstraints = false

        let prompts = [
            "Summarize what's on my screen",
            "Explain this error",
            "Improve this writing",
        ]
        let chips: [NSView] = prompts.enumerated().map { index, text in
            makePromptChip(text, tag: index)
        }
        let chipStack = NSStackView(views: chips)
        chipStack.orientation = .vertical
        chipStack.alignment = .leading
        chipStack.spacing = 8
        chipStack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSStackView(views: [title, chipStack])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 12
        container.translatesAutoresizingMaskIntoConstraints = false

        emptyState.addSubview(container)
        NSLayoutConstraint.activate([
            container.centerYAnchor.constraint(equalTo: emptyState.centerYAnchor),
            container.leadingAnchor.constraint(equalTo: emptyState.leadingAnchor, constant: 4),
            container.trailingAnchor.constraint(lessThanOrEqualTo: emptyState.trailingAnchor, constant: -4),
        ])
    }

    /// A pill-shaped tappable example-prompt chip.
    private func makePromptChip(_ text: String, tag: Int) -> NSButton {
        let chip = NSButton(title: text, target: self, action: #selector(promptChipTapped(_:)))
        chip.tag = tag
        chip.isBordered = false
        chip.bezelStyle = .regularSquare
        chip.contentTintColor = Palette.text
        chip.font = .systemFont(ofSize: 13)
        chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.07).cgColor
        chip.layer?.cornerRadius = 14
        chip.layer?.borderWidth = 1
        chip.layer?.borderColor = Palette.border.cgColor
        chip.translatesAutoresizingMaskIntoConstraints = false
        // Pad the title inside the pill.
        chip.attributedTitle = NSAttributedString(string: "   \(text)   ", attributes: [
            .foregroundColor: Palette.text,
            .font: NSFont.systemFont(ofSize: 13),
        ])
        NSLayoutConstraint.activate([
            chip.heightAnchor.constraint(equalToConstant: 30),
        ])
        return chip
    }

    @objc private func promptChipTapped(_ sender: NSButton) {
        let prompts = [
            "Summarize what's on my screen",
            "Explain this error",
            "Improve this writing",
        ]
        guard sender.tag >= 0, sender.tag < prompts.count else { return }
        let text = prompts[sender.tag]
        // The first chip is about the screen → include a screenshot.
        let withScreenshot = (sender.tag == 0)
        appendUserBubble(withScreenshot ? "📸 \(text)" : text)
        hasPendingUser = true
        onSubmit?(text, withScreenshot)
    }

    // MARK: Pin (always-on-top) toggle

    private func configurePinButton() {
        pinButton.isBordered = false
        pinButton.bezelStyle = .regularSquare
        pinButton.imagePosition = .imageOnly
        pinButton.target = self
        pinButton.action = #selector(pinTapped)
        pinButton.translatesAutoresizingMaskIntoConstraints = false
        pinButton.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            pinButton.widthAnchor.constraint(equalToConstant: 22),
            pinButton.heightAnchor.constraint(equalToConstant: 22),
        ])
        updatePinButton()
    }

    private func updatePinButton() {
        let pinned = Settings.shared.pinned
        let symbol = pinned ? "pin.fill" : "pin"
        pinButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Pin window")
        pinButton.contentTintColor = pinned ? Palette.accent : Palette.secondary
        pinButton.toolTip = pinned ? "Unpin (allow other windows on top)" : "Keep window always on top"
    }

    @objc private func pinTapped() {
        Settings.shared.pinned.toggle()
        applyPinned()
        updatePinButton()
    }

    /// Apply Settings.pinned to the panel level.
    private func applyPinned() {
        panel.level = Settings.shared.pinned ? .floating : .normal
    }

    // MARK: Provider / model chip

    private func configureProviderChip() {
        providerChip.isBordered = false
        providerChip.bezelStyle = .regularSquare
        providerChip.target = self
        providerChip.action = #selector(providerChipTapped)
        providerChip.wantsLayer = true
        providerChip.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.06).cgColor
        providerChip.layer?.cornerRadius = 11
        providerChip.layer?.borderWidth = 1
        providerChip.layer?.borderColor = Palette.border.cgColor
        providerChip.translatesAutoresizingMaskIntoConstraints = false
        providerChip.setContentHuggingPriority(.required, for: .horizontal)
        providerChip.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            providerChip.heightAnchor.constraint(equalToConstant: 22),
        ])
        updateProviderChip()
    }

    /// Refresh the chip label to the active provider + model (short form).
    private func updateProviderChip() {
        let providerId = Settings.shared.providerId
        let info = Providers.info(providerId)
        let model = Settings.shared.model.isEmpty ? (info?.defaultModel ?? "") : Settings.shared.model
        let shortModel = shortModelName(model)
        let title = shortModel.isEmpty ? (info?.label ?? providerId) : shortModel
        providerChip.attributedTitle = NSAttributedString(string: "  \(title)  ", attributes: [
            .foregroundColor: Palette.secondary,
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        ])
        providerChip.toolTip = "\(info?.label ?? providerId) · \(model)"
    }

    /// Trims provider prefixes / dates so the chip stays compact.
    private func shortModelName(_ model: String) -> String {
        var s = model
        if let slash = s.lastIndex(of: "/") {
            s = String(s[s.index(after: slash)...])
        }
        if let colon = s.firstIndex(of: ":") {
            s = String(s[..<colon])
        }
        return s
    }

    @objc private func providerChipTapped() {
        let menu = NSMenu()
        let currentProvider = Settings.shared.providerId
        let currentModel = Settings.shared.model

        for info in Providers.all {
            // Provider header → submenu of its models.
            let providerItem = NSMenuItem(title: info.label, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for model in info.models {
                let item = NSMenuItem(title: shortModelName(model), action: #selector(selectModel(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ProviderModelChoice(providerId: info.id, model: model)
                let isCurrent = (info.id == currentProvider) &&
                    (currentModel == model || (currentModel.isEmpty && model == info.defaultModel))
                item.state = isCurrent ? .on : .off
                submenu.addItem(item)
            }
            providerItem.submenu = submenu
            // Mark the active provider with a check on its header too.
            providerItem.state = (info.id == currentProvider) ? .on : .off
            menu.addItem(providerItem)
        }

        // Pop the menu just above the chip.
        let origin = NSPoint(x: 0, y: providerChip.bounds.height + 6)
        menu.popUp(positioning: nil, at: origin, in: providerChip)
    }

    /// Holds a provider+model selection for a menu item.
    private final class ProviderModelChoice: NSObject {
        let providerId: String
        let model: String
        init(providerId: String, model: String) {
            self.providerId = providerId
            self.model = model
        }
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ProviderModelChoice else { return }
        Settings.shared.providerId = choice.providerId
        Settings.shared.model = choice.model
        updateProviderChip()
    }

    // MARK: Button factories

    /// A small borderless icon button built from an SF Symbol.
    private func makeIconButton(symbol: String, tint: NSColor, action: Selector) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.contentTintColor = tint
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 22),
            button.heightAnchor.constraint(equalToConstant: 22)
        ])
        return button
    }

    /// The circular accent send button (white up-arrow on violet). Becomes a Stop
    /// button (white square) while streaming.
    private func configureSendButton() {
        sendButton.isBordered = false
        sendButton.bezelStyle = .regularSquare
        sendButton.imagePosition = .imageOnly
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        sendButton.contentTintColor = .white
        sendButton.wantsLayer = true
        sendButton.layer?.backgroundColor = Palette.accent.cgColor
        sendButton.layer?.cornerRadius = 15
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            sendButton.widthAnchor.constraint(equalToConstant: 30),
            sendButton.heightAnchor.constraint(equalToConstant: 30)
        ])
        applySendButtonAppearance()
    }

    /// Swaps the send button between Send (arrow) and Stop (square) states.
    private func applySendButtonAppearance() {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        if isStreaming {
            sendButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop")?
                .withSymbolConfiguration(config)
            sendButton.layer?.backgroundColor = Palette.pink.cgColor
            sendButton.toolTip = "Stop"
        } else {
            sendButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Send")?
                .withSymbolConfiguration(config)
            sendButton.layer?.backgroundColor = Palette.accent.cgColor
            sendButton.toolTip = "Send"
        }
    }

    // MARK: Button actions

    @objc private func cameraTapped() {
        submitFromField(includeScreenshot: true)
    }

    /// Send (or Stop, when streaming).
    @objc private func sendTapped() {
        if isStreaming {
            onStop?()
        } else {
            submitFromField(includeScreenshot: false)
        }
    }

    @objc private func godmodeTapped() {
        onGodmode?()
    }

    /// Region capture: let AppDelegate drive the region-select → solve flow.
    @objc private func regionCaptureTapped() {
        onRegionSolve?()
    }

    @objc private func settingsTapped() {
        onOpenSettings?()
    }

    @objc private func closeTapped() {
        hidePanel()
    }

    /// New chat: clear the transcript and collapse back to the input-only state.
    @objc private func newChatTapped() {
        // Stop any in-flight stream first.
        if isStreaming { onStop?() }
        for view in transcriptStack.arrangedSubviews {
            transcriptStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        transcript.removeAll()
        thinkingBubble = nil
        streamingRow = nil
        streamingRaw = ""
        isStreaming = false
        applySendButtonAppearance()
        avatar.setStreaming(false)
        hasPendingUser = false
        isExpanded = false
        onNewChat?()
        applyState(animated: true)
        panel.makeFirstResponder(inputField)
    }

    // MARK: Submission

    /// Pulls text from the input field, appends a user bubble, clears the field,
    /// and dispatches the appropriate callback. Screenshot submissions are prefixed
    /// with a camera emoji to mirror what the model is being shown.
    private func submitFromField(includeScreenshot: Bool) {
        // Read the text as robustly as possible. While editing, `stringValue` lags
        // (it holds the last committed value), and clicking Send can drop the field's
        // first responder before it commits — so prefer the live field editor, then
        // the keystroke mirror, then stringValue.
        let raw = inputField.currentEditor()?.string
            ?? (liveText.isEmpty ? inputField.stringValue : liveText)
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let display = includeScreenshot ? "📸 \(text)" : text
        appendUserBubble(display)
        // Clear the live field editor, the mirror, and the value.
        inputField.currentEditor()?.string = ""
        inputField.stringValue = ""
        liveText = ""
        hasPendingUser = true
        onSubmit?(text, includeScreenshot)
    }

    // MARK: NSTextFieldDelegate

    /// Mirror every keystroke so we always have the latest text even if the field
    /// hasn't committed (clicking Send can steal focus before commit).
    func controlTextDidChange(_ obj: Notification) {
        if let editor = obj.userInfo?["NSFieldEditor"] as? NSText {
            liveText = editor.string
        } else {
            liveText = inputField.stringValue
        }
    }

    /// Maps Return / Cmd+Return / Esc in the input field to the right action.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSEvent.modifierFlags.contains(.command) {
                inputField.onCommandReturn?()
            } else {
                inputField.onReturn?()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            inputField.onEscape?()
            return true
        default:
            return false
        }
    }

    // MARK: Message bubbles

    /// A read-only, selectable, wrapping label used for plain bubble text.
    private func makeBubbleLabel(_ text: String, color: NSColor, maxWidth: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.isEditable = false
        label.isSelectable = true
        label.drawsBackground = false
        label.isBezeled = false
        label.textColor = color
        label.font = .systemFont(ofSize: 14)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        label.preferredMaxLayoutWidth = maxWidth
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    /// A read-only, selectable label that renders an attributed (markdown) string.
    private func makeAttributedLabel(_ attr: NSAttributedString, maxWidth: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithAttributedString: attr)
        label.isEditable = false
        label.isSelectable = true
        label.allowsEditingTextAttributes = true   // makes links clickable
        label.drawsBackground = false
        label.isBezeled = false
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        label.preferredMaxLayoutWidth = maxWidth
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    /// Builds a rounded bubble container around an inner content view.
    private func makeBubble(content: NSView, fill: NSColor, padding: NSEdgeInsets) -> NSView {
        let bubble = NSView()
        bubble.wantsLayer = true
        bubble.layer?.backgroundColor = fill.cgColor
        bubble.layer?.cornerRadius = 14
        bubble.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: bubble.topAnchor, constant: padding.top),
            content.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -padding.bottom),
            content.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: padding.left),
            content.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -padding.right)
        ])
        return bubble
    }

    /// Wraps a bubble in a full-width row that aligns it left or right.
    private func makeRow(bubble: NSView, alignRight: Bool) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(bubble)
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: row.topAnchor),
            bubble.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
        if alignRight {
            bubble.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: row.leadingAnchor).isActive = true
        } else {
            bubble.leadingAnchor.constraint(equalTo: row.leadingAnchor).isActive = true
            bubble.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor).isActive = true
        }
        return row
    }

    /// Right-aligned accent bubble for user messages.
    private func appendUserBubble(_ text: String) {
        let maxWidth = panelWidth * 0.78
        let label = makeBubbleLabel(text, color: Palette.text, maxWidth: maxWidth - 28)
        let bubble = makeBubble(
            content: label,
            fill: Palette.accent.withAlphaComponent(0.20),
            padding: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        )
        bubble.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth).isActive = true
        let row = makeRow(bubble: bubble, alignRight: true)
        addRow(row)
    }

    /// Builds the inner content view for an assistant bubble by rendering MARKDOWN
    /// and fenced CODE BLOCKS into a vertical stack. Code blocks get a monospaced
    /// rounded box with a per-block Copy button.
    private func makeAssistantContent(_ raw: String, textColor: NSColor, innerWidth: CGFloat) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let segments = Markdown.splitFences(raw)
        if segments.isEmpty {
            // No content yet (start of stream): a zero-height placeholder label.
            let label = makeAttributedLabel(NSAttributedString(string: ""), maxWidth: innerWidth)
            stack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            return stack
        }

        for segment in segments {
            switch segment.kind {
            case .markdown:
                let attr = Markdown.attributed(segment.text, textColor: textColor, baseSize: 14)
                let label = makeAttributedLabel(attr, maxWidth: innerWidth)
                stack.addArrangedSubview(label)
                label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            case .code:
                let box = makeCodeBlock(segment.text, language: segment.language, innerWidth: innerWidth)
                stack.addArrangedSubview(box)
                box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        return stack
    }

    /// Holds the raw code text so the Copy button can read it back.
    private final class CodeCopyButton: NSButton {
        var codeText: String = ""
    }

    /// A monospaced rounded code box with a small Copy button in its header.
    private func makeCodeBlock(_ code: String, language: String?, innerWidth: CGFloat) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(calibratedRed: 0x05 / 255.0, green: 0x05 / 255.0, blue: 0x09 / 255.0, alpha: 0.7).cgColor
        box.layer?.cornerRadius = 10
        box.layer?.borderWidth = 1
        box.layer?.borderColor = Palette.border.cgColor
        box.translatesAutoresizingMaskIntoConstraints = false

        // Header: language label + Copy button.
        let langLabel = NSTextField(labelWithString: (language ?? "code").lowercased())
        langLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        langLabel.textColor = Palette.secondary
        langLabel.translatesAutoresizingMaskIntoConstraints = false

        let copyButton = CodeCopyButton(title: "Copy", target: self, action: #selector(copyCodeTapped(_:)))
        copyButton.codeText = code
        copyButton.isBordered = false
        copyButton.bezelStyle = .regularSquare
        copyButton.font = .systemFont(ofSize: 11, weight: .medium)
        copyButton.contentTintColor = Palette.accent
        copyButton.attributedTitle = NSAttributedString(string: "Copy", attributes: [
            .foregroundColor: Palette.accent,
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        ])
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.setContentHuggingPriority(.required, for: .horizontal)

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(langLabel)
        header.addSubview(copyButton)
        NSLayoutConstraint.activate([
            langLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            langLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            copyButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            header.heightAnchor.constraint(equalToConstant: 18),
        ])

        // Code body: selectable monospaced label.
        let codeLabel = NSTextField(wrappingLabelWithString: code)
        codeLabel.isEditable = false
        codeLabel.isSelectable = true
        codeLabel.drawsBackground = false
        codeLabel.isBezeled = false
        codeLabel.textColor = Palette.text
        codeLabel.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        codeLabel.maximumNumberOfLines = 0
        codeLabel.lineBreakMode = .byCharWrapping
        codeLabel.translatesAutoresizingMaskIntoConstraints = false
        codeLabel.preferredMaxLayoutWidth = innerWidth - 24
        codeLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        box.addSubview(header)
        box.addSubview(codeLabel)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),

            codeLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            codeLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            codeLabel.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            codeLabel.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
        ])
        return box
    }

    @objc private func copyCodeTapped(_ sender: CodeCopyButton) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(sender.codeText, forType: .string)
        // Brief visual confirmation.
        sender.attributedTitle = NSAttributedString(string: "Copied", attributes: [
            .foregroundColor: Palette.secondary,
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak sender] in
            sender?.attributedTitle = NSAttributedString(string: "Copy", attributes: [
                .foregroundColor: Palette.accent,
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            ])
        }
    }

    /// Left-aligned neutral bubble for assistant messages, rendered as MARKDOWN
    /// with fenced code blocks. When `color` is non-default (errors) the markdown
    /// renderer tints the body text accordingly.
    @discardableResult
    private func appendAssistantBubble(_ raw: String, color: NSColor = Palette.text) -> NSView {
        let maxWidth = panelWidth * 0.86
        let innerWidth = maxWidth - 28
        let content = makeAssistantContent(raw, textColor: color, innerWidth: innerWidth)
        let bubble = makeBubble(
            content: content,
            fill: NSColor(calibratedWhite: 1, alpha: 0.06),
            padding: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        )
        bubble.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth).isActive = true
        let row = makeRow(bubble: bubble, alignRight: false)
        addRow(row)
        return row
    }

    /// Replaces the rendered content inside an existing assistant bubble row with a
    /// freshly rendered version of `raw`. Used while streaming.
    private func rerenderAssistantRow(_ row: NSView, raw: String, color: NSColor = Palette.text) {
        // row → bubble (first subview) → content (first subview of bubble).
        guard let bubble = row.subviews.first else { return }
        for sub in bubble.subviews { sub.removeFromSuperview() }
        let maxWidth = panelWidth * 0.86
        let innerWidth = maxWidth - 28
        let content = makeAssistantContent(raw, textColor: color, innerWidth: innerWidth)
        content.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(content)
        let padding = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: bubble.topAnchor, constant: padding.top),
            content.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -padding.bottom),
            content.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: padding.left),
            content.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -padding.right),
        ])
    }

    /// Adds a finished row to the transcript (above any thinking bubble).
    private func addRow(_ row: NSView) {
        if let thinking = thinkingBubble,
           let index = transcriptStack.arrangedSubviews.firstIndex(of: thinking) {
            transcriptStack.insertArrangedSubview(row, at: index)
        } else {
            transcriptStack.addArrangedSubview(row)
        }
        pinRowWidth(row)
        transcript.append(row)
    }

    /// Pin a transcript row to the stack width. Must run only after the row is in
    /// `transcriptStack`: activating a constraint between views with no common
    /// ancestor throws an exception (fatal on macOS 26), which silently aborted
    /// every Send / Solve before the request was built.
    private func pinRowWidth(_ row: NSView) {
        row.widthAnchor.constraint(equalTo: transcriptStack.widthAnchor).isActive = true
    }

    // MARK: Thinking bubble

    /// Left-aligned bubble with three dots that pulse in a staggered loop.
    private func makeThinkingBubble() -> NSView {
        let dotsContainer = NSView()
        dotsContainer.translatesAutoresizingMaskIntoConstraints = false
        let dotSize: CGFloat = 7
        let spacing: CGFloat = 6
        var previous: NSView?
        for i in 0..<3 {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = Palette.secondary.cgColor
            dot.layer?.cornerRadius = dotSize / 2
            dot.translatesAutoresizingMaskIntoConstraints = false
            dotsContainer.addSubview(dot)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: dotSize),
                dot.heightAnchor.constraint(equalToConstant: dotSize),
                dot.centerYAnchor.constraint(equalTo: dotsContainer.centerYAnchor)
            ])
            if let previous {
                dot.leadingAnchor.constraint(equalTo: previous.trailingAnchor, constant: spacing).isActive = true
            } else {
                dot.leadingAnchor.constraint(equalTo: dotsContainer.leadingAnchor).isActive = true
            }
            previous = dot

            // Staggered opacity pulse.
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.25
            pulse.toValue = 1.0
            pulse.duration = 0.6
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.beginTime = CACurrentMediaTime() + Double(i) * 0.2
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.layer?.add(pulse, forKey: "pulse")
        }
        if let last = previous {
            last.trailingAnchor.constraint(equalTo: dotsContainer.trailingAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            dotsContainer.heightAnchor.constraint(equalToConstant: dotSize)
        ])

        let bubble = makeBubble(
            content: dotsContainer,
            fill: NSColor(calibratedWhite: 1, alpha: 0.06),
            padding: NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        )
        return makeRow(bubble: bubble, alignRight: false)
    }

    /// Adds the thinking bubble to the bottom of the transcript.
    private func showThinkingBubble() {
        guard thinkingBubble == nil else { return }
        let row = makeThinkingBubble()
        transcriptStack.addArrangedSubview(row)
        pinRowWidth(row)
        thinkingBubble = row
    }

    /// Removes the thinking bubble if present.
    private func removeThinkingBubble() {
        guard let row = thinkingBubble else { return }
        transcriptStack.removeArrangedSubview(row)
        row.removeFromSuperview()
        thinkingBubble = nil
    }

    // MARK: State + layout

    /// Lays the panel out for the current collapsed/expanded state, keeping the
    /// bottom edge fixed and growing/shrinking upward (unless the user moved the
    /// panel, in which case we keep its current origin).
    private func applyState(animated: Bool) {
        topBar.isHidden = !isExpanded
        transcriptScroll.isHidden = !isExpanded
        // Empty-state chips show only while expanded with no transcript content.
        emptyState.isHidden = !(isExpanded && transcript.isEmpty && thinkingBubble == nil && streamingRow == nil)
        // Collapse the top bar's height too, so the idle panel is purely the pill
        // (otherwise a hidden-but-26pt top bar leaves an empty gap above the input).
        topBarHeightConstraint.constant = isExpanded ? topBarHeight : 0

        // Compute the target panel height.
        let targetHeight: CGFloat
        let targetTranscript: CGFloat
        if isExpanded {
            // Measure the content's natural height, capped at the maximum.
            transcriptStack.layoutSubtreeIfNeeded()
            let natural = transcriptStack.fittingSize.height
            targetTranscript = min(max(natural, 60), maxTranscriptHeight)
            // chrome = top inset + topBar + gap + gap + pill + bottom inset
            let chrome = edgeInset + topBarHeight + 6 + 6 + pillHeight + edgeInset
            targetHeight = min(targetTranscript + chrome, maxPanelHeight)
        } else {
            targetTranscript = 0
            // Collapsed: top inset + (no top bar) + gap + gap + pill + bottom inset.
            targetHeight = edgeInset + 6 + 6 + pillHeight + edgeInset
        }

        transcriptHeightConstraint.constant = targetTranscript

        // Keep the panel's BOTTOM edge fixed while the height changes.
        let currentFrame = panel.frame
        let bottom = currentFrame.minY
        let newFrame = NSRect(x: currentFrame.minX,
                              y: bottom,
                              width: panelWidth,
                              height: targetHeight)

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(newFrame, display: true)
                effectView.layoutSubtreeIfNeeded()
            } completionHandler: { [weak self] in
                // The animation completion handler runs on the main thread, but the
                // closure type is nonisolated, so we assert main-actor isolation.
                MainActor.assumeIsolated {
                    self?.scrollToBottom()
                }
            }
        } else {
            panel.setFrame(newFrame, display: true)
            effectView.layoutSubtreeIfNeeded()
            scrollToBottom()
        }
    }

    /// Scrolls the transcript so the newest content is visible at the bottom.
    private func scrollToBottom() {
        guard isExpanded else { return }
        transcriptStack.layoutSubtreeIfNeeded()
        let docHeight = transcriptStack.fittingSize.height
        let clipHeight = transcriptScroll.contentView.bounds.height
        let y = max(0, docHeight - clipHeight)
        // Flipped document: larger y == further down.
        transcriptScroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        transcriptScroll.reflectScrolledClipView(transcriptScroll.contentView)
    }

    // MARK: Positioning + frame persistence

    /// Anchors the panel: restores a saved frame if present, otherwise the
    /// bottom-center of the main screen's visible frame.
    private func positionPanel() {
        if let saved = Settings.shared.savedPanelFrame(), screensContain(saved) {
            // Keep the saved x/y origin; height comes from the current state, but
            // pin the panel's bottom edge to the saved bottom so growth stays
            // anchored to where the user placed it.
            let size = panel.frame.size
            let origin = NSPoint(x: saved.minX, y: saved.minY)
            panel.setFrame(NSRect(origin: origin, size: size), display: false)
            return
        }
        guard let screen = NSScreen.main else { return }
        panel.layoutIfNeeded()
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + bottomGap
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// True if the rect's origin lands on some currently-attached screen, so we
    /// don't restore a frame onto a disconnected display.
    private func screensContain(_ rect: NSRect) -> Bool {
        let point = NSPoint(x: rect.midX, y: rect.minY + 10)
        return NSScreen.screens.contains { $0.frame.contains(point) }
    }

    /// Persist the panel's frame whenever the user moves it.
    private func observePanelMoves() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelMoved),
            name: NSWindow.didMoveNotification,
            object: panel
        )
    }

    @objc private func panelMoved() {
        Settings.shared.setPanelFrame(panel.frame)
    }

    // MARK: Public API

    /// Show or hide the panel, depending on current visibility.
    func toggle() {
        if panel.isVisible {
            hidePanel()
        } else {
            showForAsk()
        }
    }

    /// Position, bring forward, activate, and focus the input field. Does NOT clear
    /// the transcript — only "new chat" does that.
    func showForAsk() {
        positionPanel()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(inputField)
    }

    /// Hide the panel.
    func hidePanel() {
        panel.orderOut(nil)
    }

    /// Show or hide the thinking indicator.
    ///
    /// When turned on without a pending user message (e.g. a hotkey-initiated Solve
    /// or Godmode that bypasses the input field), a placeholder user bubble is added
    /// so the transcript reads coherently.
    func setThinking(_ on: Bool) {
        if on {
            if !hasPendingUser {
                appendUserBubble("📸 Screenshot")
                hasPendingUser = true
            }
            isExpanded = true
            showThinkingBubble()
            ensureVisible()
            applyState(animated: true)
        } else {
            removeThinkingBubble()
        }
    }

    /// Display an answer: stop thinking, append an assistant bubble, expand, scroll.
    func showAnswer(_ text: String) {
        setThinking(false)
        appendAssistantBubble(text)
        hasPendingUser = false
        isExpanded = true
        ensureVisible()
        applyState(animated: true)
    }

    /// Display an error bubble (assistant-style, tinted red, prefixed ⚠︎).
    func showError(_ message: String) {
        setThinking(false)
        isStreaming = false
        applySendButtonAppearance()
        avatar.setStreaming(false)
        let errorColor = NSColor(calibratedRed: 0xff / 255.0, green: 0x7a / 255.0, blue: 0x8a / 255.0, alpha: 1)
        appendAssistantBubble("⚠︎ \(message)", color: errorColor)
        streamingRow = nil
        streamingRaw = ""
        hasPendingUser = false
        isExpanded = true
        ensureVisible()
        applyState(animated: true)
    }

    // MARK: Streaming API

    /// Begin a streaming assistant response: remove the thinking dots, add an empty
    /// assistant bubble we'll grow, and swap Send → Stop.
    func beginStreaming() {
        removeThinkingBubble()
        isExpanded = true
        isStreaming = true
        streamingRaw = ""
        streamingRow = appendAssistantBubble("")
        hasPendingUser = false
        applySendButtonAppearance()
        avatar.setStreaming(true)
        ensureVisible()
        applyState(animated: true)
    }

    /// Append a delta to the streaming bubble and re-render its markdown, staying
    /// scrolled to the bottom.
    func appendDelta(_ s: String) {
        guard isStreaming else { return }
        if streamingRow == nil {
            // Defensive: begin a stream if appendDelta is called first.
            beginStreaming()
        }
        streamingRaw += s
        if let row = streamingRow {
            rerenderAssistantRow(row, raw: streamingRaw)
        }
        applyState(animated: false)
        scrollToBottom()
    }

    /// Finalize the streaming bubble and swap Stop → Send.
    func endStreaming() {
        isStreaming = false
        applySendButtonAppearance()
        avatar.setStreaming(false)
        // Re-render once more so the final markdown is clean.
        if let row = streamingRow {
            rerenderAssistantRow(row, raw: streamingRaw)
        }
        streamingRow = nil
        streamingRaw = ""
        isExpanded = true
        ensureVisible()
        applyState(animated: true)
    }

    /// Brings the panel up (positioned + key) if it isn't already showing.
    private func ensureVisible() {
        if !panel.isVisible {
            positionPanel()
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }
}
