import Foundation
import Security
import ServiceManagement

// MARK: - Carbon modifier flag constants
//
// HotKey.swift / RegisterEventHotKey expect Carbon modifier masks (cmdKey,
// shiftKey, optionKey, controlKey). We re-declare the values here as plain
// UInt32 so Persistence has no dependency on the Carbon import — the values are
// fixed by the platform ABI.
private enum CarbonMod {
    static let cmd: UInt32 = 1 << 8      // cmdKey      = 0x0100
    static let shift: UInt32 = 1 << 9    // shiftKey    = 0x0200
    static let option: UInt32 = 1 << 11  // optionKey   = 0x0800
    static let control: UInt32 = 1 << 12 // controlKey  = 0x1000
}

/// Thin wrapper over the macOS Keychain for storing provider API keys.
/// Uses a generic-password item keyed by `account` under a single service.
enum Keychain {
    /// The Keychain service all Smartii items live under.
    private static let service = "app.smartii.mac"

    /// Store (or replace) the string `value` for the given `account`.
    /// Implemented as delete-then-add so updates are idempotent.
    static func set(_ value: String, account: String) {
        delete(account: account)

        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    /// Fetch the stored string for `account`, or nil if absent / unreadable.
    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Remove the stored item for `account` (no-op if it does not exist).
    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - HotKeyAction

/// The user-rebindable global hot keys.
public enum HotKeyAction: String, CaseIterable {
    case ask
    case solve
    case godmode
    case panic

    /// Human-readable label used in the settings recorder rows.
    public var title: String {
        switch self {
        case .ask: return "Ask"
        case .solve: return "Solve screen"
        case .godmode: return "Godmode"
        case .panic: return "Panic (hide)"
        }
    }

    /// Factory defaults expressed as Carbon (keyCode, modifiers) pairs.
    ///
    /// - ask     = ⌘⇧S   keyCode 1 (S), cmd|shift
    /// - solve   = ⌥⇧S   keyCode 1 (S), option|shift
    /// - godmode = ⌥⇧G   keyCode 5 (G), option|shift
    /// - panic   = ⌥⇧X   keyCode 7 (X), option|shift
    var defaultHotKey: (keyCode: UInt32, modifiers: UInt32) {
        switch self {
        case .ask:
            return (1, CarbonMod.cmd | CarbonMod.shift)
        case .solve:
            return (1, CarbonMod.option | CarbonMod.shift)
        case .godmode:
            return (5, CarbonMod.option | CarbonMod.shift)
        case .panic:
            return (7, CarbonMod.option | CarbonMod.shift)
        }
    }
}

/// App-wide settings: non-secret values in UserDefaults, API keys in the Keychain.
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let provider = "provider"
        static let model = "model"
        static let autoCopyAnswer = "autoCopyAnswer"
        static let didOnboard = "didOnboard"
        static let pinned = "pinned"
        static let soundsEnabled = "soundsEnabled"
        static let sendContext = "sendContext"
        static let godmodeAutofill = "godmodeAutofill"
        static let panelFrame = "panelFrame"
        static let compactScreenshotAnswers = "compactScreenshotAnswers"

        /// UserDefaults keys for a hot key's keyCode / modifiers.
        static func hotKeyCode(_ action: HotKeyAction) -> String {
            "hotkey.\(action.rawValue).keyCode"
        }
        static func hotKeyMods(_ action: HotKeyAction) -> String {
            "hotkey.\(action.rawValue).modifiers"
        }
    }

    private init() {}

    /// Whether the first-launch welcome window has been shown/dismissed.
    var didOnboard: Bool {
        get { defaults.bool(forKey: Key.didOnboard) }
        set { defaults.set(newValue, forKey: Key.didOnboard) }
    }

    /// Selected provider id (default "gemini").
    var providerId: String {
        get { defaults.string(forKey: Key.provider) ?? "gemini" }
        set { defaults.set(newValue, forKey: Key.provider) }
    }

    /// Selected model id; empty string means "use the provider default".
    var model: String {
        get { defaults.string(forKey: Key.model) ?? "" }
        set { defaults.set(newValue, forKey: Key.model) }
    }

    /// Whether to auto-copy answers to the clipboard.
    /// Defaults to true when the key has never been written.
    var autoCopyAnswer: Bool {
        get {
            // A missing key must be treated as `true`; UserDefaults.bool
            // returns false for missing keys, so check existence first.
            if defaults.object(forKey: Key.autoCopyAnswer) == nil { return true }
            return defaults.bool(forKey: Key.autoCopyAnswer)
        }
        set { defaults.set(newValue, forKey: Key.autoCopyAnswer) }
    }

    /// Show hotkey / menu screenshot answers in the compact corner card instead of
    /// the chat panel. Defaults to true when the key has never been written.
    var compactScreenshotAnswers: Bool {
        get {
            if defaults.object(forKey: Key.compactScreenshotAnswers) == nil { return true }
            return defaults.bool(forKey: Key.compactScreenshotAnswers)
        }
        set { defaults.set(newValue, forKey: Key.compactScreenshotAnswers) }
    }

    /// Read the API key for a provider from the Keychain.
    func apiKey(for providerId: String) -> String? {
        Keychain.get(account: "key.\(providerId)")
    }

    /// Persist the API key for a provider into the Keychain.
    func setAPIKey(_ key: String, for providerId: String) {
        Keychain.set(key, account: "key.\(providerId)")
    }

    // MARK: Launch at login

    /// Whether Smartii is registered as a login item.
    ///
    /// Getter reflects the live `SMAppService.mainApp` status; setter
    /// registers / unregisters (errors are swallowed with `try?`).
    var launchAtLogin: Bool {
        get {
            SMAppService.mainApp.status == .enabled
        }
        set {
            if newValue {
                try? SMAppService.mainApp.register()
            } else {
                try? SMAppService.mainApp.unregister()
            }
        }
    }

    // MARK: Window / behaviour toggles

    /// Whether the panel is pinned (always-on-top). Persisted as a plain bool.
    var pinned: Bool {
        get { defaults.bool(forKey: Key.pinned) }
        set { defaults.set(newValue, forKey: Key.pinned) }
    }

    /// Whether subtle UI sounds play on send / receive. Default false.
    var soundsEnabled: Bool {
        get { defaults.bool(forKey: Key.soundsEnabled) }
        set { defaults.set(newValue, forKey: Key.soundsEnabled) }
    }

    /// Whether prior conversation turns are sent as context. Default true.
    var sendContext: Bool {
        get {
            // Missing key defaults to true (conversation memory on).
            if defaults.object(forKey: Key.sendContext) == nil { return true }
            return defaults.bool(forKey: Key.sendContext)
        }
        set { defaults.set(newValue, forKey: Key.sendContext) }
    }

    /// Whether a Godmode answer is auto-typed into the focused field. Default false.
    var godmodeAutofill: Bool {
        get { defaults.bool(forKey: Key.godmodeAutofill) }
        set { defaults.set(newValue, forKey: Key.godmodeAutofill) }
    }

    // MARK: Panel frame

    /// Last-saved panel frame, or nil if never persisted.
    func savedPanelFrame() -> NSRect? {
        guard let s = defaults.string(forKey: Key.panelFrame) else { return nil }
        let rect = NSRectFromString(s)
        // A zero-sized rect means the stored string was unparseable / empty.
        if rect.width == 0 && rect.height == 0 { return nil }
        return rect
    }

    /// Persist the panel frame for restore on next launch.
    func setPanelFrame(_ frame: NSRect) {
        defaults.set(NSStringFromRect(frame), forKey: Key.panelFrame)
    }

    // MARK: Custom hot keys

    /// The (keyCode, modifiers) for an action — saved value, or the default.
    func hotKey(for action: HotKeyAction) -> (keyCode: UInt32, modifiers: UInt32) {
        let codeKey = Key.hotKeyCode(action)
        let modsKey = Key.hotKeyMods(action)

        // Both halves must be present, otherwise fall back to the default.
        guard defaults.object(forKey: codeKey) != nil,
              defaults.object(forKey: modsKey) != nil else {
            return action.defaultHotKey
        }

        let code = UInt32(bitPattern: Int32(truncatingIfNeeded: defaults.integer(forKey: codeKey)))
        let mods = UInt32(bitPattern: Int32(truncatingIfNeeded: defaults.integer(forKey: modsKey)))
        return (code, mods)
    }

    /// Persist a custom (keyCode, modifiers) for an action.
    func setHotKey(_ keyCode: UInt32, _ modifiers: UInt32, for action: HotKeyAction) {
        defaults.set(Int(keyCode), forKey: Key.hotKeyCode(action))
        defaults.set(Int(modifiers), forKey: Key.hotKeyMods(action))
    }
}

// MARK: - History

/// One saved question/answer pair.
struct HistoryItem: Codable {
    let id: UUID
    let date: Date
    let question: String
    let answer: String
    var pinned: Bool
}

/// Persistent, capped history of asked questions and their answers.
///
/// Stored as JSON at `~/Library/Application Support/Smartii/history.json`.
final class HistoryStore {
    static let shared = HistoryStore()

    /// Maximum number of items retained.
    private let cap = 200

    /// Serialises access to `items` + disk writes.
    private let queue = DispatchQueue(label: "app.smartii.history")

    private var items: [HistoryItem] = []

    private let fileURL: URL

    private init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Smartii", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        items = Self.load(from: fileURL)
    }

    private static func load(from url: URL) -> [HistoryItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HistoryItem].self, from: data)) ?? []
    }

    /// Persist the current items to disk. Caller holds `queue`.
    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Prepend a new question/answer, capping the list and persisting.
    func add(question: String, answer: String) {
        queue.sync {
            let item = HistoryItem(
                id: UUID(),
                date: Date(),
                question: question,
                answer: answer,
                pinned: false
            )
            items.insert(item, at: 0)
            if items.count > cap {
                // Keep pinned items even past the cap; trim oldest unpinned.
                var trimmed: [HistoryItem] = []
                var unpinnedCount = 0
                for it in items {
                    if it.pinned {
                        trimmed.append(it)
                    } else if unpinnedCount < cap {
                        trimmed.append(it)
                        unpinnedCount += 1
                    }
                }
                items = Array(trimmed.prefix(cap + items.filter { $0.pinned }.count))
                if items.count > cap {
                    // Final safety trim from the tail of unpinned entries.
                    items = Array(items.prefix(cap))
                }
            }
            persist()
        }
    }

    /// All items, newest first.
    func all() -> [HistoryItem] {
        queue.sync { items }
    }

    /// Case-insensitive search over question + answer text.
    func search(_ query: String) -> [HistoryItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all() }
        return queue.sync {
            items.filter {
                $0.question.range(of: q, options: .caseInsensitive) != nil
                    || $0.answer.range(of: q, options: .caseInsensitive) != nil
            }
        }
    }

    /// Toggle the pinned flag of the item with `id` and persist.
    func togglePin(_ id: UUID) {
        queue.sync {
            guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
            items[idx].pinned.toggle()
            persist()
        }
    }

    /// Remove all items and persist the empty list.
    func clear() {
        queue.sync {
            items.removeAll()
            persist()
        }
    }
}

// MARK: - Streaks

/// Tracks how many problems were solved today and the running day streak.
final class Streaks {
    static let shared = Streaks()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let dayStart = "streak.dayStart"   // start-of-day timestamp of the current count
        static let todayCount = "streak.todayCount"
        static let streakDays = "streak.days"      // consecutive days with >=1 solve
        static let lastSolveDay = "streak.lastSolveDay" // start-of-day of last recorded solve
    }

    private init() {}

    /// Number of solves recorded today; resets to 0 once the calendar day changes.
    var solvedToday: Int {
        let today = Self.startOfToday()
        let storedDay = defaults.double(forKey: Key.dayStart)
        if storedDay != today.timeIntervalSinceReferenceDate {
            return 0
        }
        return defaults.integer(forKey: Key.todayCount)
    }

    /// The current consecutive-day streak (days with at least one solve).
    var streakDays: Int {
        // If the last solve was before yesterday, the streak has lapsed.
        let last = defaults.double(forKey: Key.lastSolveDay)
        guard last != 0 else { return 0 }
        let lastDay = Date(timeIntervalSinceReferenceDate: last)
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: lastDay), to: Self.startOfToday()).day ?? 0
        if days > 1 { return 0 }
        return defaults.integer(forKey: Key.streakDays)
    }

    /// Record a solved problem: bumps today's count and maintains the day streak.
    func recordSolve() {
        let today = Self.startOfToday()
        let todayTS = today.timeIntervalSinceReferenceDate

        // Reset today's counter if the day rolled over.
        let storedDay = defaults.double(forKey: Key.dayStart)
        if storedDay != todayTS {
            defaults.set(todayTS, forKey: Key.dayStart)
            defaults.set(0, forKey: Key.todayCount)
        }
        defaults.set(defaults.integer(forKey: Key.todayCount) + 1, forKey: Key.todayCount)

        // Maintain the consecutive-day streak.
        let cal = Calendar.current
        let lastTS = defaults.double(forKey: Key.lastSolveDay)
        if lastTS == 0 {
            defaults.set(1, forKey: Key.streakDays)
        } else if lastTS != todayTS {
            let lastDay = Date(timeIntervalSinceReferenceDate: lastTS)
            let gap = cal.dateComponents([.day], from: cal.startOfDay(for: lastDay), to: today).day ?? 0
            if gap == 1 {
                defaults.set(defaults.integer(forKey: Key.streakDays) + 1, forKey: Key.streakDays)
            } else {
                // Missed one or more days — start a fresh streak.
                defaults.set(1, forKey: Key.streakDays)
            }
        }
        // Same day repeated solve: streakDays unchanged.
        defaults.set(todayTS, forKey: Key.lastSolveDay)
    }

    /// Reference-time start of the current calendar day.
    private static func startOfToday() -> Date {
        Calendar.current.startOfDay(for: Date())
    }
}
