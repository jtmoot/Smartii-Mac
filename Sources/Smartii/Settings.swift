import Cocoa
import QuartzCore
import Carbon.HIToolbox

// MARK: - SettingsWindowController

/// A translucent "glass" settings card that matches the welcome window and the
/// chat box: dark vibrant material, violet accent, the Smartii logo, generous
/// spacing. Borderless + rounded via a mask image; dismiss with Save, ✕, or Esc.
///
/// Extends the original provider/key/model/copy card with: launch-at-login,
/// a "Test key" ping, a Gemini recommender badge, a Permissions card (Screen
/// Recording + Accessibility), Play-sounds / Send-context / Godmode-autofill
/// toggles, four custom hotkey recorder rows, and an "Open History…" button.
@MainActor
final class SettingsWindowController: NSObject {

    private let window: WelcomeWindow
    private let scroll = NSScrollView()
    private let card = NSVisualEffectView()
    private let documentView = NSView()

    private let providerPopup = NSPopUpButton()
    private let keyField = NSSecureTextField()
    private let modelPopup = NSPopUpButton()
    private let copyCheckbox = NSButton(checkboxWithTitle: "Copy answers to the clipboard", target: nil, action: nil)
    private let soundsCheckbox = NSButton(checkboxWithTitle: "Play sounds", target: nil, action: nil)
    private let contextCheckbox = NSButton(checkboxWithTitle: "Send recent messages for context", target: nil, action: nil)
    private let godmodeCheckbox = NSButton(checkboxWithTitle: "Godmode types the answer into the focused field", target: nil, action: nil)
    private let compactCheckbox = NSButton(checkboxWithTitle: "Show screenshot answers in a small corner card", target: nil, action: nil)
    private let launchCheckbox = NSButton(checkboxWithTitle: "Launch Smartii at login", target: nil, action: nil)
    private let getKeyButton = NSButton()
    private let testKeyButton = NSButton()
    private let testKeyStatus = NSTextField(labelWithString: "")
    private let recommendBadge = NSTextField(labelWithString: "Free & fast — recommended")
    private let statusLabel = NSTextField(labelWithString: "")

    // Permissions card labels (refreshed when the window is shown).
    private let screenStatus = NSTextField(labelWithString: "")
    private let axStatus = NSTextField(labelWithString: "")

    // Hotkey recorders, one per action.
    private var recorders: [HotKeyAction: HotKeyRecorderView] = [:]

    private var historyController: HistoryWindowController?
    private var escMonitor: Any?
    private var testTask: Task<Void, Never>?

    private enum S {
        static let width: CGFloat = 520
        static let height: CGFloat = 640
        static let inset: CGFloat = 26
        static let corner: CGFloat = 20
        static var contentW: CGFloat { width - inset * 2 }
        static let accent = Palette.accent
        static let pink = NSColor(srgbRed: 0xff / 255, green: 0x5e / 255, blue: 0x9c / 255, alpha: 1)
        static let ok = NSColor(srgbRed: 0x4c / 255, green: 0xd9 / 255, blue: 0x6b / 255, alpha: 1)
        static let bad = NSColor(srgbRed: 0xff / 255, green: 0x6b / 255, blue: 0x6b / 255, alpha: 1)
    }

    override init() {
        window = WelcomeWindow(
            contentRect: NSRect(x: 0, y: 0, width: S.width, height: S.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // Render the native popups / secure field in dark so they fit the card.
        window.appearance = NSAppearance(named: .darkAqua)
        buildContent()
        loadFromSettings()
    }

    // MARK: Layout

    private func buildContent() {
        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.maskImage = roundedMask(S.corner)
        window.contentView = card

        // Violet top glow + hairline border, clipped to the rounded shape.
        let chrome = NSView()
        chrome.wantsLayer = true
        chrome.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(chrome)
        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: card.topAnchor),
            chrome.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            chrome.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        if let host = chrome.layer {
            host.cornerRadius = S.corner
            host.masksToBounds = true
            let glow = CAGradientLayer()
            glow.frame = CGRect(x: 0, y: 0, width: S.width, height: S.height)
            glow.colors = [
                S.accent.withAlphaComponent(0.26).cgColor,
                S.pink.withAlphaComponent(0.06).cgColor,
                NSColor.clear.cgColor,
            ]
            glow.locations = [0.0, 0.22, 0.5]
            glow.startPoint = CGPoint(x: 0.5, y: 1.0)
            glow.endPoint = CGPoint(x: 0.5, y: 0.0)
            host.addSublayer(glow)
            let border = CAShapeLayer()
            border.path = CGPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: S.width - 1, height: S.height - 1),
                                 cornerWidth: S.corner, cornerHeight: S.corner, transform: nil)
            border.fillColor = NSColor.clear.cgColor
            border.strokeColor = Palette.border.cgColor
            border.lineWidth = 1
            host.addSublayer(border)
        }

        // Close button (pinned to the card, above the scroll content).
        let close = NSButton(title: "✕", target: self, action: #selector(closeTapped))
        close.isBordered = false
        close.bezelStyle = .regularSquare
        close.contentTintColor = Palette.secondary
        close.font = .systemFont(ofSize: 15, weight: .medium)
        close.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(close)
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            close.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            close.widthAnchor.constraint(equalToConstant: 28),
            close.heightAnchor.constraint(equalToConstant: 28),
        ])

        // A scroll view so the (now much taller) content always fits.
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = documentView
        card.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: card.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])

        buildSections()
    }

    private func buildSections() {
        // Header: logo + title.
        let logo = NSImageView()
        logo.image = logoImage()
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: 34).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let title = NSTextField(labelWithString: "Settings")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.textColor = Palette.text

        let header = NSStackView(views: [logo, title])
        header.orientation = .horizontal
        header.spacing = 12
        header.alignment = .centerY

        let subtitle = NSTextField(labelWithString: "Pick a provider and paste your API key. Keys are stored in your macOS Keychain.")
        subtitle.font = .systemFont(ofSize: 12.5)
        subtitle.textColor = Palette.secondary
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 0
        subtitle.preferredMaxLayoutWidth = S.contentW

        // Provider.
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        providerPopup.translatesAutoresizingMaskIntoConstraints = false
        providerPopup.widthAnchor.constraint(equalToConstant: S.contentW).isActive = true
        for info in Providers.all {
            providerPopup.addItem(withTitle: "\(info.label)  ·  \(info.tier)")
            providerPopup.lastItem?.representedObject = info.id
        }

        // Gemini recommender badge (a small pill, shown only for gemini).
        recommendBadge.font = .systemFont(ofSize: 11, weight: .semibold)
        recommendBadge.textColor = S.ok
        recommendBadge.wantsLayer = true
        recommendBadge.drawsBackground = false
        recommendBadge.layer?.backgroundColor = S.ok.withAlphaComponent(0.12).cgColor
        recommendBadge.layer?.cornerRadius = 7
        recommendBadge.layer?.borderWidth = 1
        recommendBadge.layer?.borderColor = S.ok.withAlphaComponent(0.35).cgColor
        recommendBadge.alignment = .center
        recommendBadge.translatesAutoresizingMaskIntoConstraints = false
        recommendBadge.heightAnchor.constraint(equalToConstant: 20).isActive = true
        recommendBadge.setContentHuggingPriority(.required, for: .horizontal)
        // Pad the badge with leading/trailing whitespace via attributed string insets.
        let badgeRow = NSStackView(views: [recommendBadge, NSView()])
        badgeRow.orientation = .horizontal
        badgeRow.alignment = .centerY

        // API key + "Get a key" link + "Test" button.
        keyField.placeholderString = "Paste your API key"
        keyField.font = .systemFont(ofSize: 13)
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyField.heightAnchor.constraint(equalToConstant: 26).isActive = true

        getKeyButton.title = "Get a key →"
        getKeyButton.bezelStyle = .inline
        getKeyButton.isBordered = false
        getKeyButton.contentTintColor = S.accent
        getKeyButton.font = .systemFont(ofSize: 12.5, weight: .medium)
        getKeyButton.target = self
        getKeyButton.action = #selector(getKeyTapped)
        getKeyButton.setContentHuggingPriority(.required, for: .horizontal)

        let keyRow = NSStackView(views: [keyField, getKeyButton])
        keyRow.orientation = .horizontal
        keyRow.spacing = 10
        keyRow.alignment = .centerY
        keyRow.translatesAutoresizingMaskIntoConstraints = false
        keyRow.widthAnchor.constraint(equalToConstant: S.contentW).isActive = true

        // Test key row.
        testKeyButton.title = "Test key"
        testKeyButton.bezelStyle = .rounded
        testKeyButton.target = self
        testKeyButton.action = #selector(testKeyTapped)
        testKeyButton.controlSize = .small
        testKeyButton.setContentHuggingPriority(.required, for: .horizontal)
        testKeyStatus.font = .systemFont(ofSize: 12, weight: .medium)
        testKeyStatus.textColor = Palette.secondary
        let testRow = NSStackView(views: [testKeyButton, testKeyStatus, NSView()])
        testRow.orientation = .horizontal
        testRow.spacing = 10
        testRow.alignment = .centerY

        // Model.
        modelPopup.translatesAutoresizingMaskIntoConstraints = false
        modelPopup.widthAnchor.constraint(equalToConstant: S.contentW).isActive = true

        // Checkboxes.
        for box in [copyCheckbox, soundsCheckbox, contextCheckbox, godmodeCheckbox, compactCheckbox, launchCheckbox] {
            box.target = self
            if let cell = box.cell as? NSButtonCell { cell.font = .systemFont(ofSize: 13) }
            box.contentTintColor = Palette.text
        }
        launchCheckbox.action = #selector(launchToggled)

        // Permissions card.
        let permissions = buildPermissionsCard()

        // Hotkeys card.
        let hotkeys = buildHotkeysCard()

        // History + Save row.
        let historyButton = ghostButton("Open History…", #selector(openHistoryTapped))
        let saveButton = filledButton("Save", #selector(saveTapped))
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = Palette.secondary
        let saveRow = NSStackView(views: [historyButton, statusLabel, NSView(), saveButton])
        saveRow.orientation = .horizontal
        saveRow.alignment = .centerY
        saveRow.spacing = 10
        saveRow.distribution = .fill
        saveRow.translatesAutoresizingMaskIntoConstraints = false
        saveRow.widthAnchor.constraint(equalToConstant: S.contentW).isActive = true
        saveButton.setContentHuggingPriority(.required, for: .horizontal)
        historyButton.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [
            header,
            subtitle,
            spacer(6),
            caption("Provider"), providerPopup, badgeRow,
            caption("API key"), keyRow, testRow,
            caption("Model"), modelPopup,
            spacer(4),
            sectionTitle("General"),
            copyCheckbox,
            soundsCheckbox,
            contextCheckbox,
            godmodeCheckbox,
            compactCheckbox,
            launchCheckbox,
            spacer(6),
            permissions,
            spacer(6),
            hotkeys,
            spacer(8),
            saveRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: subtitle)
        stack.setCustomSpacing(4, after: providerPopup)
        stack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: S.inset),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: S.inset),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -S.inset),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -S.inset),
        ])
    }

    // MARK: Permissions card

    private func buildPermissionsCard() -> NSView {
        let titleLabel = sectionTitle("Permissions")

        let screenRow = permissionRow(
            name: "Screen Recording",
            statusLabel: screenStatus,
            action: #selector(openScreenRecordingSettings)
        )
        let axRow = permissionRow(
            name: "Accessibility",
            statusLabel: axStatus,
            action: #selector(openAccessibilitySettings)
        )

        let stack = NSStackView(views: [titleLabel, screenRow, axRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return cardContainer(stack)
    }

    private func permissionRow(name: String, statusLabel: NSTextField, action: Selector) -> NSView {
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = Palette.text
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.textColor = Palette.secondary
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        let openButton = NSButton(title: "Open System Settings", target: self, action: action)
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        openButton.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [label, statusLabel, openButton])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: S.contentW - 24).isActive = true
        return row
    }

    // MARK: Hotkeys card

    private func buildHotkeysCard() -> NSView {
        let titleLabel = sectionTitle("Shortcuts")
        let hint = NSTextField(labelWithString: "Click a shortcut, then press the new key combination.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = Palette.secondary

        var rows: [NSView] = [titleLabel, hint]
        for action in HotKeyAction.allCases {
            let label = NSTextField(labelWithString: action.title)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = Palette.text
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)

            let recorder = HotKeyRecorderView(action: action) { [weak self] keyCode, modifiers in
                Settings.shared.setHotKey(keyCode, modifiers, for: action)
                NotificationCenter.default.post(name: Notification.Name("SmartiiHotKeysChanged"), object: nil)
                self?.refreshRecorders()
            }
            recorders[action] = recorder

            let row = NSStackView(views: [label, NSView(), recorder])
            row.orientation = .horizontal
            row.spacing = 10
            row.alignment = .centerY
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: S.contentW - 24).isActive = true
            rows.append(row)
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return cardContainer(stack)
    }

    /// Wraps `content` in a subtly-tinted rounded card matching the panel style.
    private func cardContainer(_ content: NSView) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.04).cgColor
        container.layer?.cornerRadius = 12
        container.layer?.borderWidth = 1
        container.layer?.borderColor = Palette.border.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: S.contentW).isActive = true

        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        return container
    }

    // MARK: Builders

    private func caption(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s.uppercased())
        l.font = .systemFont(ofSize: 10.5, weight: .semibold)
        l.textColor = Palette.secondary
        return l
    }

    private func sectionTitle(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 13, weight: .bold)
        l.textColor = Palette.text
        return l
    }

    private func spacer(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    private func filledButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.isBordered = false
        b.wantsLayer = true
        b.bezelStyle = .regularSquare
        b.layer?.backgroundColor = Palette.accent.cgColor
        b.layer?.cornerRadius = 9
        b.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold)]
        )
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 34).isActive = true
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        return b
    }

    private func ghostButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.isBordered = false
        b.wantsLayer = true
        b.bezelStyle = .regularSquare
        b.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.06).cgColor
        b.layer?.cornerRadius = 9
        b.layer?.borderWidth = 1
        b.layer?.borderColor = Palette.border.cgColor
        b.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: Palette.text, .font: NSFont.systemFont(ofSize: 13, weight: .medium)]
        )
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return b
    }

    private func roundedMask(_ r: CGFloat) -> NSImage {
        let edge = r * 2 + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }

    private func logoImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "SmartiiLogo", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: "Settings")
    }

    // MARK: State

    private var selectedProviderId: String {
        providerPopup.selectedItem?.representedObject as? String ?? Settings.shared.providerId
    }

    private var selectedModel: String {
        modelPopup.selectedItem?.representedObject as? String ?? ""
    }

    private func loadFromSettings() {
        let settings = Settings.shared
        let id = settings.providerId
        if let index = providerPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == id }) {
            providerPopup.selectItem(at: index)
        }
        rebuildModelPopup(for: id, selecting: settings.model)
        keyField.stringValue = settings.apiKey(for: id) ?? ""
        copyCheckbox.state = settings.autoCopyAnswer ? .on : .off
        soundsCheckbox.state = settings.soundsEnabled ? .on : .off
        contextCheckbox.state = settings.sendContext ? .on : .off
        godmodeCheckbox.state = settings.godmodeAutofill ? .on : .off
        compactCheckbox.state = settings.compactScreenshotAnswers ? .on : .off
        launchCheckbox.state = settings.launchAtLogin ? .on : .off
        statusLabel.stringValue = ""
        testKeyStatus.stringValue = ""
        updateRecommendBadge()
        refreshRecorders()
        refreshPermissions()
    }

    private func rebuildModelPopup(for providerId: String, selecting model: String) {
        modelPopup.removeAllItems()
        modelPopup.addItem(withTitle: "Default (recommended)")
        modelPopup.lastItem?.representedObject = ""
        if let info = Providers.info(providerId) {
            for m in info.models {
                modelPopup.addItem(withTitle: m)
                modelPopup.lastItem?.representedObject = m
            }
        }
        if !model.isEmpty,
           let index = modelPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == model }) {
            modelPopup.selectItem(at: index)
        } else {
            modelPopup.selectItem(at: 0)
        }
    }

    private func updateRecommendBadge() {
        // The Gemini recommender note only shows when Gemini is selected.
        recommendBadge.isHidden = (selectedProviderId != "gemini")
        recommendBadge.stringValue = "  Free & fast — recommended  "
    }

    private func refreshRecorders() {
        for (action, recorder) in recorders {
            let hk = Settings.shared.hotKey(for: action)
            recorder.update(keyCode: hk.keyCode, modifiers: hk.modifiers)
        }
    }

    private func refreshPermissions() {
        let screenOK = CGPreflightScreenCaptureAccess()
        screenStatus.stringValue = screenOK ? "Granted ✓" : "Not granted ✗"
        screenStatus.textColor = screenOK ? S.ok : S.bad

        let axOK = AX.isTrusted
        axStatus.stringValue = axOK ? "Granted ✓" : "Not granted ✗"
        axStatus.textColor = axOK ? S.ok : S.bad
    }

    // MARK: Actions

    @objc private func providerChanged() {
        let id = selectedProviderId
        rebuildModelPopup(for: id, selecting: "")
        keyField.stringValue = Settings.shared.apiKey(for: id) ?? ""
        testKeyStatus.stringValue = ""
        updateRecommendBadge()
    }

    @objc private func getKeyTapped() {
        guard let info = Providers.info(selectedProviderId), let url = URL(string: info.keyURL) else { return }
        NSWorkspace.shared.open(url)
    }

    /// The key as currently typed/pasted — reads the live field editor so a value
    /// pasted right before clicking Test/Save isn't missed (stringValue lags until
    /// the field commits).
    private func liveKey() -> String {
        (keyField.currentEditor()?.string ?? keyField.stringValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func testKeyTapped() {
        let id = selectedProviderId
        let key = liveKey()
        let model = selectedModel
        guard !key.isEmpty else {
            testKeyStatus.stringValue = "Paste a key first"
            testKeyStatus.textColor = S.bad
            return
        }
        testKeyStatus.stringValue = "Testing…"
        testKeyStatus.textColor = Palette.secondary
        testKeyButton.isEnabled = false
        testTask?.cancel()
        testTask = Task { [weak self] in
            do {
                _ = try await Providers.call(
                    providerId: id,
                    apiKey: key,
                    prompt: "Reply with OK",
                    imageDataURL: nil,
                    model: model.isEmpty ? nil : model
                )
                await MainActor.run {
                    guard let self else { return }
                    self.testKeyStatus.stringValue = "Works ✓"
                    self.testKeyStatus.toolTip = nil
                    self.testKeyStatus.textColor = S.ok
                    self.testKeyButton.isEnabled = true
                }
            } catch is CancellationError {
                // re-tested; ignore
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                let short = msg.count > 90 ? String(msg.prefix(90)) + "…" : msg
                await MainActor.run {
                    guard let self else { return }
                    self.testKeyStatus.stringValue = "✗ " + short
                    self.testKeyStatus.toolTip = msg
                    self.testKeyStatus.textColor = S.bad
                    self.testKeyButton.isEnabled = true
                }
            }
        }
    }

    @objc private func launchToggled() {
        Settings.shared.launchAtLogin = (launchCheckbox.state == .on)
        // Reflect the actual resulting state (registration can silently fail).
        launchCheckbox.state = Settings.shared.launchAtLogin ? .on : .off
    }

    @objc private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openHistoryTapped() {
        let controller = historyController ?? HistoryWindowController()
        historyController = controller
        controller.show()
    }

    @objc private func saveTapped() {
        let settings = Settings.shared
        let id = selectedProviderId
        settings.providerId = id
        settings.model = selectedModel
        settings.autoCopyAnswer = (copyCheckbox.state == .on)
        settings.soundsEnabled = (soundsCheckbox.state == .on)
        settings.sendContext = (contextCheckbox.state == .on)
        settings.godmodeAutofill = (godmodeCheckbox.state == .on)
        settings.compactScreenshotAnswers = (compactCheckbox.state == .on)
        let key = liveKey()
        if !key.isEmpty { settings.setAPIKey(key, for: id) }
        statusLabel.stringValue = "Saved ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            self?.close()
        }
    }

    @objc private func closeTapped() { close() }

    private func close() {
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        for recorder in recorders.values { recorder.stopRecording() }
        testTask?.cancel()
        window.orderOut(nil)
    }

    // MARK: Public API

    func show() {
        loadFromSettings()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        refreshPermissions()
        if escMonitor == nil {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                // Don't swallow Esc while a recorder is capturing — let it cancel.
                if self.recorders.values.contains(where: { $0.isRecording }) { return event }
                if event.keyCode == 53 { self.close(); return nil }
                return event
            }
        }
    }
}

// MARK: - HotKeyRecorderView

/// A small pill-shaped control that captures the next key combination. Clicking
/// it enters "recording" mode; the next key-down with at least one modifier is
/// translated to a Carbon (keyCode, modifiers) pair and reported via `onCapture`.
/// Esc cancels recording without changing the binding.
@MainActor
final class HotKeyRecorderView: NSView {

    let action: HotKeyAction
    private let onCapture: (UInt32, UInt32) -> Void
    private let label = NSTextField(labelWithString: "")
    private(set) var isRecording = false
    private var monitor: Any?

    private var keyCode: UInt32 = 0
    private var modifiers: UInt32 = 0

    init(action: HotKeyAction, onCapture: @escaping (UInt32, UInt32) -> Void) {
        self.action = action
        self.onCapture = onCapture
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 26))
        wantsLayer = true
        layer?.backgroundColor = Palette.field.cgColor
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.borderColor = Palette.border.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 150).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true

        label.alignment = .center
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.textColor = Palette.text
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Sets the displayed combo without entering recording mode.
    func update(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        renderLabel()
    }

    override func mouseDown(with event: NSEvent) {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        isRecording = true
        label.stringValue = "Press keys…"
        label.textColor = Palette.accent
        layer?.borderColor = Palette.accent.cgColor
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Esc cancels.
            if event.keyCode == 53 {
                self.stopRecording()
                return nil
            }
            let carbonMods = Self.carbonModifiers(from: event.modifierFlags)
            // Require at least one modifier so combos don't clash with typing.
            guard carbonMods != 0 else { return nil }
            let code = UInt32(event.keyCode)
            self.keyCode = code
            self.modifiers = carbonMods
            self.stopRecording()
            self.onCapture(code, carbonMods)
            return nil
        }
    }

    /// Ends recording mode and restores the resting appearance.
    func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        isRecording = false
        label.textColor = Palette.text
        layer?.borderColor = Palette.border.cgColor
        renderLabel()
    }

    private func renderLabel() {
        label.stringValue = Self.describe(keyCode: keyCode, modifiers: modifiers)
    }

    // MARK: Carbon <-> NSEvent translation

    /// Maps Cocoa modifier flags to the Carbon modifier mask used by RegisterEventHotKey.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    /// Renders a (keyCode, carbon modifiers) pair as e.g. "⌘⇧S".
    static func describe(keyCode: UInt32, modifiers: UInt32) -> String {
        var prefix = ""
        if modifiers & UInt32(controlKey) != 0 { prefix += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { prefix += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { prefix += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { prefix += "⌘" }
        return prefix + keyName(keyCode)
    }

    /// Human-readable name for a Carbon/HIToolbox virtual key code.
    static func keyName(_ keyCode: UInt32) -> String {
        let map: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
            50: "`", 51: "⌫", 53: "⎋", 65: ".", 67: "*", 69: "+",
            71: "Clear", 75: "/", 76: "↩", 78: "-", 81: "=", 82: "0",
            83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7",
            91: "8", 92: "9", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
            100: "F8", 101: "F9", 103: "F11", 105: "F13", 107: "F14",
            109: "F10", 111: "F12", 113: "F15", 114: "Help", 115: "Home",
            116: "Page Up", 117: "⌦", 118: "F4", 119: "End", 120: "F2",
            121: "Page Down", 122: "F1", 123: "←", 124: "→", 125: "↓",
            126: "↑",
        ]
        return map[keyCode] ?? "Key \(keyCode)"
    }
}

// MARK: - HistoryWindowController

/// A glass window listing the answer history. Each row shows the question and a
/// snippet of the answer with a pin toggle and a copy button. A search field
/// filters the list (via HistoryStore.search) and a "Clear" button wipes it.
@MainActor
final class HistoryWindowController: NSObject {

    private let window: WelcomeWindow
    private let card = NSVisualEffectView()
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No history yet.")

    private var items: [HistoryItem] = []
    private var escMonitor: Any?

    private enum S {
        static let width: CGFloat = 560
        static let height: CGFloat = 560
        static let inset: CGFloat = 22
        static let corner: CGFloat = 20
        static var contentW: CGFloat { width - inset * 2 }
        static let accent = Palette.accent
        static let pink = NSColor(srgbRed: 0xff / 255, green: 0x5e / 255, blue: 0x9c / 255, alpha: 1)
    }

    override init() {
        window = WelcomeWindow(
            contentRect: NSRect(x: 0, y: 0, width: S.width, height: S.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        buildContent()
    }

    // MARK: Layout

    private func buildContent() {
        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.maskImage = roundedMask(S.corner)
        window.contentView = card

        let chrome = NSView()
        chrome.wantsLayer = true
        chrome.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(chrome)
        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: card.topAnchor),
            chrome.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            chrome.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        if let host = chrome.layer {
            host.cornerRadius = S.corner
            host.masksToBounds = true
            let glow = CAGradientLayer()
            glow.frame = CGRect(x: 0, y: 0, width: S.width, height: S.height)
            glow.colors = [
                S.accent.withAlphaComponent(0.26).cgColor,
                S.pink.withAlphaComponent(0.06).cgColor,
                NSColor.clear.cgColor,
            ]
            glow.locations = [0.0, 0.22, 0.5]
            glow.startPoint = CGPoint(x: 0.5, y: 1.0)
            glow.endPoint = CGPoint(x: 0.5, y: 0.0)
            host.addSublayer(glow)
            let border = CAShapeLayer()
            border.path = CGPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: S.width - 1, height: S.height - 1),
                                 cornerWidth: S.corner, cornerHeight: S.corner, transform: nil)
            border.fillColor = NSColor.clear.cgColor
            border.strokeColor = Palette.border.cgColor
            border.lineWidth = 1
            host.addSublayer(border)
        }

        // Header: title + close.
        let title = NSTextField(labelWithString: "History")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.textColor = Palette.text
        title.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(title)

        let close = NSButton(title: "✕", target: self, action: #selector(closeTapped))
        close.isBordered = false
        close.bezelStyle = .regularSquare
        close.contentTintColor = Palette.secondary
        close.font = .systemFont(ofSize: 15, weight: .medium)
        close.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(close)

        // Search field.
        searchField.placeholderString = "Search history"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false
        card.addSubview(searchField)

        // Table.
        tableView.backgroundColor = .clear
        tableView.headerView = nil
        tableView.rowHeight = 64
        tableView.intercellSpacing = NSSize(width: 0, height: 6)
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.dataSource = self
        tableView.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scroll.documentView = tableView
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(scroll)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = Palette.secondary
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(emptyLabel)

        // Clear button.
        let clearButton = NSButton(title: "Clear", target: self, action: #selector(clearTapped))
        clearButton.bezelStyle = .rounded
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(clearButton)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: S.inset),

            close.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            close.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            close.widthAnchor.constraint(equalToConstant: 28),
            close.heightAnchor.constraint(equalToConstant: 28),

            searchField.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: S.inset),
            searchField.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -S.inset),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: S.inset),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -S.inset),
            scroll.bottomAnchor.constraint(equalTo: clearButton.topAnchor, constant: -14),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            clearButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: S.inset),
            clearButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -S.inset),
        ])
    }

    private func roundedMask(_ r: CGFloat) -> NSImage {
        let edge = r * 2 + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }

    private func reload(query: String? = nil) {
        let q = query ?? searchField.stringValue
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        items = trimmed.isEmpty ? HistoryStore.shared.all() : HistoryStore.shared.search(trimmed)
        emptyLabel.isHidden = !items.isEmpty
        tableView.reloadData()
    }

    // MARK: Actions

    @objc private func searchChanged() { reload() }

    @objc private func clearTapped() {
        HistoryStore.shared.clear()
        reload()
    }

    @objc fileprivate func pinTapped(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < items.count else { return }
        HistoryStore.shared.togglePin(items[sender.tag].id)
        reload()
    }

    @objc fileprivate func copyTapped(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < items.count else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(items[sender.tag].answer, forType: .string)
    }

    @objc private func closeTapped() { close() }

    private func close() {
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        window.orderOut(nil)
    }

    // MARK: Public API

    func show() {
        reload()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if escMonitor == nil {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                // Let the search field keep Esc when it's editing.
                if self.window.firstResponder is NSText, !self.searchField.stringValue.isEmpty { return event }
                if event.keyCode == 53 { self.close(); return nil }
                return event
            }
        }
    }
}

// MARK: - HistoryWindowController data source / delegate

extension HistoryWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < items.count else { return nil }
        let item = items[row]
        let id = NSUserInterfaceItemIdentifier("HistoryRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? HistoryRowView) ?? HistoryRowView(identifier: id)
        cell.configure(
            question: item.question,
            answer: item.answer,
            date: item.date,
            pinned: item.pinned,
            row: row,
            pinTarget: self,
            pinAction: #selector(pinTapped(_:)),
            copyTarget: self,
            copyAction: #selector(copyTapped(_:))
        )
        return cell
    }
}

// MARK: - HistoryRowView

/// One history entry: question (bold) + answer snippet, with a pin toggle and a
/// copy button on the trailing edge. Rendered in a subtly-tinted rounded card.
@MainActor
final class HistoryRowView: NSTableCellView {

    private let container = NSView()
    private let questionLabel = NSTextField(labelWithString: "")
    private let snippetLabel = NSTextField(labelWithString: "")
    private let pinButton = NSButton()
    private let copyButton = NSButton()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.04).cgColor
        container.layer?.cornerRadius = 10
        container.layer?.borderWidth = 1
        container.layer?.borderColor = Palette.border.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)

        questionLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        questionLabel.textColor = Palette.text
        questionLabel.lineBreakMode = .byTruncatingTail
        questionLabel.maximumNumberOfLines = 1
        questionLabel.translatesAutoresizingMaskIntoConstraints = false

        snippetLabel.font = .systemFont(ofSize: 12)
        snippetLabel.textColor = Palette.secondary
        snippetLabel.lineBreakMode = .byTruncatingTail
        snippetLabel.maximumNumberOfLines = 2
        snippetLabel.translatesAutoresizingMaskIntoConstraints = false

        pinButton.bezelStyle = .regularSquare
        pinButton.isBordered = false
        pinButton.imagePosition = .imageOnly
        pinButton.translatesAutoresizingMaskIntoConstraints = false

        copyButton.bezelStyle = .regularSquare
        copyButton.isBordered = false
        copyButton.imagePosition = .imageOnly
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        copyButton.contentTintColor = Palette.secondary
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [questionLabel, snippetLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(textStack)
        container.addSubview(pinButton)
        container.addSubview(copyButton)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            copyButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            copyButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 22),
            copyButton.heightAnchor.constraint(equalToConstant: 22),

            pinButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -8),
            pinButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: 22),
            pinButton.heightAnchor.constraint(equalToConstant: 22),

            textStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: pinButton.leadingAnchor, constant: -10),
            textStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        question: String,
        answer: String,
        date: Date,
        pinned: Bool,
        row: Int,
        pinTarget: AnyObject,
        pinAction: Selector,
        copyTarget: AnyObject,
        copyAction: Selector
    ) {
        questionLabel.stringValue = question.isEmpty ? "(screenshot)" : question
        let snippet = answer.replacingOccurrences(of: "\n", with: " ")
        snippetLabel.stringValue = snippet

        pinButton.image = NSImage(
            systemSymbolName: pinned ? "pin.fill" : "pin",
            accessibilityDescription: pinned ? "Unpin" : "Pin"
        )
        pinButton.contentTintColor = pinned ? Palette.accent : Palette.secondary

        pinButton.target = pinTarget
        pinButton.action = pinAction
        pinButton.tag = row
        copyButton.target = copyTarget
        copyButton.action = copyAction
        copyButton.tag = row

        container.layer?.borderColor = pinned
            ? Palette.accent.withAlphaComponent(0.4).cgColor
            : Palette.border.cgColor
    }
}
