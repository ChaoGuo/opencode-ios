import Foundation

/// Persists the most recent assistant message id we have shown the user in each
/// session. The background refresh task uses this as a baseline to decide what
/// counts as "new" — without persistence we'd re-notify the same message every
/// wake-up, because the live in-memory envelopes are gone after the app is
/// suspended or killed.
final class MessageCursorStore {
    static let shared = MessageCursorStore()

    private let defaults: UserDefaults
    private let storageKey = "opencode_message_cursors_v1"
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// sessionID → last-seen assistant messageID
    private func load() -> [String: String] {
        defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }

    private func save(_ dict: [String: String]) {
        defaults.set(dict, forKey: storageKey)
    }

    func cursor(for sessionID: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return load()[sessionID]
    }

    func setCursor(_ messageID: String, for sessionID: String) {
        lock.lock(); defer { lock.unlock() }
        var dict = load()
        if dict[sessionID] == messageID { return }
        dict[sessionID] = messageID
        save(dict)
    }

    func clear(sessionID: String) {
        lock.lock(); defer { lock.unlock() }
        var dict = load()
        if dict.removeValue(forKey: sessionID) != nil {
            save(dict)
        }
    }

    func clearAll() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: storageKey)
    }
}
