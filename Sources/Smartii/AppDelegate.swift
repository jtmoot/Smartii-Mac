import Cocoa
import Carbon.HIToolbox

// AppDelegate — the glue of Smartii for Mac.
//
// Owns the menu-bar status item, the floating answer panel (BarController) and the
// settings / history windows. Registers four user-rebindable global hotkeys and
// routes both the hotkeys and the menu items into the same handful of async flows
// that talk to the AI providers — now via STREAMING (Providers.stream) with a
// cancellable Task, conversation memory, history/streak/sound side effects, and an
// optional Godmode autofill into the focused field.
//
// Default hotkey bindings (rebindable in Settings — see Settings.hotKey(for:)):
//   ⌘⇧S  toggle / ask        ⌥⇧S  solve screen
//   ⌥⇧G  godmode             ⌥⇧X  panic (hide panel)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // The GODMODE prompt is fed verbatim to the provider alongside a screenshot.
    private static let godmodePrompt = """
    GODMODE: read the entire attached screenshot of the user's screen. Identify the \
    most important question, problem, code, error, or task on screen and answer it \
    directly and completely. If there are multiple questions, answer all of them, \
    numbered. If it's a multiple-choice question, give the correct letter AND the \
    reasoning. If it's code or an error, show the fix. Be precise. No filler.
    """

    // Generic instruction used when the user submits a screenshot with no typed text.
    private static let screenshotOnlyPrompt = """
    Read the attached screenshot of the user's screen and answer the most important \
    question or task shown. Be direct and complete.
    """

    /// Notification posted by Settings when the user rebinds any hotkey.
    private static let hotKeysChanged = Notification.Name("SmartiiHotKeysChanged")

    private var statusItem: NSStatusItem?
    private let bar = BarController()
    private let card = AnswerCardController()

    /// Where a solve shows its answer: the full chat panel, or the compact corner
    /// card (hotkey / menu screenshot solves, when enabled in Settings).
    enum AnswerPresentation { case panel, card }
    private let settingsController = SettingsWindowController()
    private let welcomeController = WelcomeWindowController()
    private let historyController = HistoryWindowController()

    // MARK: - Conversation memory

    /// One turn of the running conversation. `role` is "user" or "assistant".
    private struct Turn { let role: String; let text: String }

    /// Mutable per-stream UI state. MainActor-isolated so it can be mutated from
    /// the `Task { @MainActor }` hops inside the `@Sendable` onDelta closure
    /// without crossing an isolation boundary with a mutable local.
    @MainActor
    private final class StreamState {
        var started = false
        var accumulated = ""
    }

    /// Prior turns, included in the prompt when Settings.sendContext is on.
    /// Cleared whenever the user starts a new chat (bar.onNewChat).
    private var memory: [Turn] = []

    // MARK: - Streaming state

    /// The in-flight streaming task, retained so Stop / a new request can cancel it.
    private var streamTask: Task<Void, Never>?

    /// The menu item that shows today's solve count; refreshed when the menu opens.
    private weak var solvedTodayItem: NSMenuItem?

    /// Generation counter for hotkey registrations. Carbon's HotKeyManager can
    /// only `register` (there is no unregister in its public API), so on rebind
    /// we register a fresh set and bump this counter; handlers from earlier
    /// generations become no-ops, so only the latest bindings fire.
    private var hotKeyGeneration = 0

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        setUpStatusItem()
        wireBarController()
        registerHotKeys()

        // Re-register hotkeys whenever the user rebinds them in Settings.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotKeysChangedNotification),
            name: AppDelegate.hotKeysChanged,
            object: nil
        )

        // First launch: show the welcome / onboarding window once.
        welcomeController.onOpenSettings = { [weak self] in
            self?.settingsController.show()
        }
        if !Settings.shared.didOnboard {
            welcomeController.show()
        }

        // Quietly check for a newer release shortly after launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            Updater.shared.checkInBackground()
        }
    }

    // MARK: - Main menu (enables standard editing shortcuts)

    /// An accessory (LSUIElement) app has no application menu, so the standard
    /// editing key-equivalents (⌘C/⌘V/⌘X/⌘A/⌘Z) have nothing in the responder
    /// chain to fire — hence the error beep when pasting. Installing a minimal
    /// main menu with an Edit submenu restores Cut/Copy/Paste/Select All/Undo in
    /// every text field, even though the menu bar itself isn't shown.
    private func installEditMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Smartii", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status item & menu

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = AppDelegate.makeMenuBarIcon()

        let menu = NSMenu()
        menu.delegate = self

        let ask = NSMenuItem(title: "Ask Smartii  ⌘⇧S",
                             action: #selector(menuAsk), keyEquivalent: "")
        ask.target = self
        menu.addItem(ask)

        let solve = NSMenuItem(title: "Solve screen  ⌥⇧S",
                               action: #selector(menuSolveScreen), keyEquivalent: "")
        solve.target = self
        menu.addItem(solve)

        let region = NSMenuItem(title: "Solve region…",
                                action: #selector(menuSolveRegion), keyEquivalent: "")
        region.target = self
        menu.addItem(region)

        let godmodeItem = NSMenuItem(title: "⚡ Godmode  ⌥⇧G",
                                     action: #selector(menuGodmode), keyEquivalent: "")
        godmodeItem.target = self
        menu.addItem(godmodeItem)

        menu.addItem(.separator())

        // Disabled info row showing how many problems were solved today.
        let solvedToday = NSMenuItem(title: "Solved today: 0", action: nil, keyEquivalent: "")
        solvedToday.isEnabled = false
        menu.addItem(solvedToday)
        solvedTodayItem = solvedToday

        let history = NSMenuItem(title: "History…",
                                 action: #selector(menuHistory), keyEquivalent: "")
        history.target = self
        menu.addItem(history)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(menuSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        let checkUpdates = NSMenuItem(title: "Check for Updates…",
                                      action: #selector(menuCheckForUpdates), keyEquivalent: "")
        checkUpdates.target = self
        menu.addItem(checkUpdates)

        let welcome = NSMenuItem(title: "Welcome / Help",
                                 action: #selector(menuWelcome), keyEquivalent: "")
        welcome.target = self
        menu.addItem(welcome)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Smartii",
                              action: #selector(menuQuit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    /// Builds the Smartii robot menu-bar glyph as a template image.
    ///
    /// The art is a simplified vector of the Smartii mascot: a rounded-square head
    /// with two punched-out round eyes and a short antenna ending in a small bulb.
    /// Everything is drawn in pure black; marking the image as a template lets the
    /// system recolor it (white on the typical dark menu bar, dark when highlighted).
    private static func makeMenuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            // ----- Head: a rounded square, roughly centered, ~13×12. -----
            let headRect = NSRect(x: 2.5, y: 2.5, width: 13.0, height: 11.5)
            let head = NSBezierPath(roundedRect: headRect, xRadius: 3.2, yRadius: 3.2)

            // Two round eyes, punched out of the head via even-odd winding.
            let eyeRadius: CGFloat = 1.7
            let eyeY = headRect.midY - 0.3
            let leftEyeCenter = NSPoint(x: headRect.midX - 2.9, y: eyeY)
            let rightEyeCenter = NSPoint(x: headRect.midX + 2.9, y: eyeY)
            for center in [leftEyeCenter, rightEyeCenter] {
                let eyeRect = NSRect(x: center.x - eyeRadius,
                                     y: center.y - eyeRadius,
                                     width: eyeRadius * 2,
                                     height: eyeRadius * 2)
                head.appendOval(in: eyeRect)
            }
            head.windingRule = .evenOdd
            NSColor.black.setFill()
            head.fill()

            // ----- Antenna: a thin stalk rising ~2.5px from the top center… -----
            let antenna = NSBezierPath()
            let stalkBottom = NSPoint(x: headRect.midX, y: headRect.maxY)
            let stalkTop = NSPoint(x: headRect.midX, y: headRect.maxY + 2.0)
            antenna.move(to: stalkBottom)
            antenna.line(to: stalkTop)
            antenna.lineWidth = 1.2
            antenna.lineCapStyle = .round
            NSColor.black.setStroke()
            antenna.stroke()

            // …topped by a small filled bulb.
            let bulbRadius: CGFloat = 1.5
            let bulbRect = NSRect(x: stalkTop.x - bulbRadius,
                                  y: stalkTop.y,
                                  width: bulbRadius * 2,
                                  height: bulbRadius * 2)
            let bulb = NSBezierPath(ovalIn: bulbRect)
            NSColor.black.setFill()
            bulb.fill()

            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Smartii"
        return image
    }

    // MARK: - BarController wiring

    private func wireBarController() {
        // The panel hands us the typed text and whether it was a Solve (screenshot) submit.
        bar.onSubmit = { [weak self] text, includeScreenshot in
            Sound.send()
            self?.solve(text: text, includeScreenshot: includeScreenshot, presentation: .panel)
        }
        bar.onGodmode = { [weak self] in
            self?.godmode(presentation: .panel)
        }
        bar.onOpenSettings = { [weak self] in
            self?.settingsController.show()
        }
        // User tapped Stop while a response was streaming — cancel the in-flight task.
        bar.onStop = { [weak self] in
            self?.cancelStream()
        }
        // User cleared the chat — drop the conversation memory.
        bar.onNewChat = { [weak self] in
            self?.cancelStream()
            self?.memory.removeAll()
        }
        // User chose region capture from the panel.
        bar.onRegionSolve = { [weak self] in
            self?.solveRegion(presentation: .panel)
        }
    }

    // MARK: - Global hotkeys

    /// (Re)register the four global hotkeys from the user's saved bindings.
    ///
    /// Safe to call repeatedly. Since HotKeyManager only exposes `register`, each
    /// call bumps `hotKeyGeneration` and the freshly registered handlers capture
    /// that value; handlers from a prior generation short-circuit, so only the
    /// most recent bindings act.
    private func registerHotKeys() {
        hotKeyGeneration += 1
        let generation = hotKeyGeneration
        let settings = Settings.shared

        /// Register one action's hotkey with a generation guard around `body`.
        func bind(_ action: HotKeyAction, _ body: @escaping () -> Void) {
            let combo = settings.hotKey(for: action)
            HotKeyManager.shared.register(keyCode: combo.keyCode, modifiers: combo.modifiers) { [weak self] in
                guard let self, self.hotKeyGeneration == generation else { return }
                body()
            }
        }

        // ask — toggle the ask panel.
        bind(.ask) { [weak self] in self?.toggleBar() }
        // solve — capture the screen and solve it.
        bind(.solve) { [weak self] in self?.solveScreen() }
        // godmode — capture + answer everything on screen.
        bind(.godmode) { [weak self] in self?.godmode() }
        // panic — cancel any stream and hide the panel instantly.
        bind(.panic) { [weak self] in
            self?.cancelStream()
            self?.bar.hidePanel()
            self?.card.hide()
        }
    }

    @objc private func hotKeysChangedNotification() {
        registerHotKeys()
    }

    // MARK: - Menu actions
    //
    // Each menu item routes into exactly the same flow as its matching hotkey.

    @objc private func menuAsk() { toggleBar() }
    @objc private func menuSolveScreen() { solveScreen() }
    @objc private func menuSolveRegion() { solveRegion() }
    @objc private func menuGodmode() { godmode() }
    @objc private func menuHistory() { historyController.show() }
    @objc private func menuSettings() { settingsController.show() }
    @objc private func menuCheckForUpdates() { Updater.shared.checkAndPrompt() }
    @objc private func menuWelcome() { welcomeController.show() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: - Flows

    /// Toggle the floating ask panel.
    func toggleBar() {
        bar.toggle()
    }

    /// Capture the whole screen and solve it with no typed prompt.
    func solveScreen(presentation: AnswerPresentation = .card) {
        solve(text: "", includeScreenshot: true, presentation: presentation)
    }

    /// Pick the surface for `presentation`, hiding the chat panel when the card wins.
    private func sink(for presentation: AnswerPresentation) -> AnswerSink {
        if presentation == .card && Settings.shared.compactScreenshotAnswers {
            bar.hidePanel()
            return card
        }
        return bar
    }

    /// Capture a user-selected region of the screen and solve it.
    func solveRegion(presentation: AnswerPresentation = .card) {
        Task { @MainActor in
            let sink = self.sink(for: presentation)
            // Hide the panel so it isn't part of the region selection, give the
            // window server a beat, then show the drag-to-select overlay.
            bar.hidePanel()
            try? await Task.sleep(nanoseconds: 200_000_000)

            guard let imageDataURL = await Screenshot.captureRegion() else {
                // Cancelled (Esc / no drag) or capture failed — nothing to do.
                return
            }
            runSolve(text: AppDelegate.screenshotOnlyPrompt,
                     imageDataURL: imageDataURL,
                     isGodmode: false,
                     sink: sink)
        }
    }

    /// Godmode — screenshot the screen and run the verbatim GODMODE prompt.
    func godmode(presentation: AnswerPresentation = .card) {
        solve(text: AppDelegate.godmodePrompt, includeScreenshot: true, isGodmode: true, presentation: presentation)
    }

    /// Optionally screenshot the screen, then run the streaming solve.
    ///
    /// - Parameters:
    ///   - text: the user's prompt (may be empty for a pure screenshot solve).
    ///   - includeScreenshot: capture the main display and attach it to the request.
    ///   - isGodmode: whether this is a Godmode answer (drives the autofill behaviour).
    /// Turns a provider error into a friendlier message, adding a hint for the
    /// common OpenRouter free-model "data policy" rejection.
    private func friendlyError(_ error: Error) -> String {
        let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let lower = msg.lowercased()
        if lower.contains("data policy") || lower.contains("no endpoints") || lower.contains("no allowed providers") {
            return msg + "\n\nTip: free OpenRouter models need a one-time opt-in — enable them at openrouter.ai/settings/privacy, then try again."
        }
        return msg
    }

    func solve(text: String, includeScreenshot: Bool, isGodmode: Bool = false,
               presentation: AnswerPresentation = .panel) {
        Task { @MainActor in
            let settings = Settings.shared
            let sink = self.sink(for: presentation)
            let providerId = settings.providerId

            // Require an API key for the chosen provider (Ollama runs keyless).
            let key = settings.apiKey(for: providerId) ?? ""
            if providerId != "ollama" && key.isEmpty {
                let label = Providers.info(providerId)?.label ?? providerId
                bar.showError("No API key set for \(label). Open Settings to add one.")
                bar.showForAsk()
                settingsController.show()
                return
            }

            // Optionally grab a screenshot. Hide our own panel first so it isn't
            // captured, let the window server hide it, then shoot.
            var imageDataURL: String? = nil
            if includeScreenshot {
                bar.hidePanel()
                try? await Task.sleep(nanoseconds: 250_000_000) // 0.25s

                let img = await Screenshot.captureMainDisplay()
                guard let img else {
                    sink.showError("Couldn't capture the screen. Grant Screen Recording "
                                  + "permission in System Settings → Privacy & Security → "
                                  + "Screen Recording, then try again.")
                    return
                }
                imageDataURL = img
            }

            runSolve(text: text,
                     imageDataURL: imageDataURL,
                     isGodmode: isGodmode,
                     sink: sink)
        }
    }

    /// The core streaming flow shared by every entry point. Builds the prompt
    /// (including prior turns when context is on), streams the answer into the
    /// panel, records side effects, and on Godmode optionally types the answer
    /// into the focused field.
    ///
    /// Note: `bar.setThinking(true)` adds a placeholder user bubble when there is
    /// no pending typed message (screenshot / region / godmode entry points), so
    /// the transcript reads coherently without extra plumbing here.
    private func runSolve(text: String,
                          imageDataURL: String?,
                          isGodmode: Bool,
                          sink: AnswerSink) {
        let settings = Settings.shared
        let providerId = settings.providerId
        let apiKey = settings.apiKey(for: providerId) ?? ""
        let model = settings.model.isEmpty ? nil : settings.model

        // An empty prompt with a screenshot gets a generic "read & answer" instruction.
        let basePrompt: String
        if text.isEmpty && imageDataURL != nil {
            basePrompt = AppDelegate.screenshotOnlyPrompt
        } else {
            basePrompt = text
        }

        // The history question we store mirrors what the user effectively asked.
        let historyQuestion = (text.isEmpty && imageDataURL != nil) ? "📸 Screenshot" : text

        // Prepend prior turns as plain text context when conversation memory is on.
        let prompt = buildPrompt(base: basePrompt, useContext: settings.sendContext)

        // Replace any in-flight stream.
        cancelStream()

        sink.setThinking(true)

        // MainActor-isolated streaming state, mutated only on the MainActor.
        let state = StreamState()

        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Bridge the synchronous @Sendable onDelta callbacks into an ordered
            // AsyncStream so we consume deltas one-at-a-time, in order, on the
            // MainActor. The producer runs the provider call; the consumer (this
            // task) updates the UI as each chunk arrives.
            let stream = AsyncThrowingStream<String, Error> { continuation in
                let producer = Task {
                    do {
                        try await Providers.stream(
                            providerId: providerId,
                            apiKey: apiKey,
                            prompt: prompt,
                            imageDataURL: imageDataURL,
                            model: model
                        ) { delta in
                            continuation.yield(delta)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in producer.cancel() }
            }

            do {
                for try await delta in stream {
                    try Task.checkCancellation()
                    if !state.started {
                        state.started = true
                        sink.setThinking(false)
                        sink.beginStreaming()
                    }
                    state.accumulated += delta
                    sink.appendDelta(delta)
                }

                // The stream may be cancelled between the last delta and here.
                try Task.checkCancellation()

                if state.started { sink.endStreaming() }

                if state.accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Streaming produced no visible text — common with reasoning
                    // models (e.g. Nemotron) that stream their thinking but the
                    // final answer arrives via the non-streaming field. Fall back.
                    let answer = try await Providers.call(
                        providerId: providerId, apiKey: apiKey, prompt: prompt,
                        imageDataURL: imageDataURL, model: model)
                    sink.setThinking(false)
                    sink.showAnswer(answer)
                    self.finishAnswer(question: historyQuestion, answer: answer, isGodmode: isGodmode)
                } else {
                    self.finishAnswer(question: historyQuestion,
                                      answer: state.accumulated,
                                      isGodmode: isGodmode)
                }
            } catch is CancellationError {
                // User pressed Stop / Panic / started a new request: finalize quietly.
                if state.started { sink.endStreaming() }
                sink.setThinking(false)
            } catch {
                // Streaming failed — try one normal (non-streaming) request before
                // surfacing the error, so an SSE-specific hiccup doesn't block the chat.
                if state.started { sink.endStreaming() }
                do {
                    try Task.checkCancellation()
                    let answer = try await Providers.call(
                        providerId: providerId, apiKey: apiKey, prompt: prompt,
                        imageDataURL: imageDataURL, model: model)
                    sink.setThinking(false)
                    sink.showAnswer(answer)
                    self.finishAnswer(question: historyQuestion, answer: answer, isGodmode: isGodmode)
                } catch is CancellationError {
                    sink.setThinking(false)
                } catch let fallbackError {
                    sink.setThinking(false)
                    sink.showError(self.friendlyError(fallbackError))
                }
            }
            self.streamTask = nil
        }
    }

    /// Records the completed answer: memory, auto-copy, history, streak, sound,
    /// and (for Godmode) optional autofill into the focused field.
    private func finishAnswer(question: String, answer: String, isGodmode: Bool) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Conversation memory: append both turns for the next request.
        memory.append(Turn(role: "user", text: question))
        memory.append(Turn(role: "assistant", text: answer))

        // Auto-copy to the clipboard if enabled.
        if Settings.shared.autoCopyAnswer {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(answer, forType: .string)
        }

        // Persistent side effects on every completed answer.
        HistoryStore.shared.add(question: question, answer: answer)
        Streaks.shared.recordSolve()
        Sound.receive()

        // Godmode autofill: type the answer into the focused field when enabled
        // and we're trusted for the Accessibility API.
        if isGodmode && Settings.shared.godmodeAutofill && AX.isTrusted {
            _ = AX.fillFocusedField(answer)
        }
    }

    /// Builds the prompt sent to the provider. When `useContext` is on, prior
    /// turns are rendered as a labelled transcript above the current prompt so
    /// any (even non-chat) provider gets conversation memory.
    private func buildPrompt(base: String, useContext: Bool) -> String {
        guard useContext, !memory.isEmpty else { return base }

        var lines: [String] = []
        for turn in memory {
            let label = turn.role == "assistant" ? "Assistant" : "User"
            lines.append("\(label): \(turn.text)")
        }
        lines.append("User: \(base)")
        lines.append("Assistant:")
        return lines.joined(separator: "\n\n")
    }

    /// Cancel the in-flight streaming task, if any.
    private func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    /// Refresh the dynamic "Solved today: N" row each time the menu opens.
    func menuWillOpen(_ menu: NSMenu) {
        solvedTodayItem?.title = "Solved today: \(Streaks.shared.solvedToday)"
    }
}
