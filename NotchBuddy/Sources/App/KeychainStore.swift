import Foundation
import Security

// MARK: - Keychain helpers

enum Keychain {
    static let service = "fr.louisraille.NotchBuddy"

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        // Delete existing item first (update pattern)
        let lookup: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(lookup as CFDictionary)
        // Add with strictest access control:
        // WhenUnlockedThisDeviceOnly = accessible only while Mac is unlocked,
        // never synced to iCloud, never migrated to another device.
        let item: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      key,
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Keychain cache (each key read lazily, at most once; then served from memory)

/// Thread-safe cache over `Keychain`. A key is read from the Keychain the first time someone
/// asks for it (on that caller's thread: the pollers' background queues, or a view), then
/// served from memory; `set` and `remove` keep the cache in step, so it is never read again.
/// Any key works, there is no list to keep up to date. Nothing is read at launch: a key that
/// is never used is never read, and never asks for Keychain access.
final class KeychainStore: @unchecked Sendable {
    static let shared = KeychainStore(backend: .system)

    /// Where values live: the real Keychain, or a fake in tests.
    struct Backend: Sendable {
        var load: @Sendable (String) -> String?
        var save: @Sendable (String, String) -> Void
        var delete: @Sendable (String) -> Void

        static let system = Backend(load: { Keychain.load(key: $0) },
                                    save: { Keychain.save(key: $0, value: $1) },
                                    delete: { Keychain.delete(key: $0) })
    }

    /// One key's cached value. Its lock makes the first read happen once, even when several
    /// threads ask at the same time, without making other keys wait for it.
    private final class Slot: @unchecked Sendable {
        let lock = NSLock()
        var loaded = false
        var value: String?
    }

    private var slots: [String: Slot] = [:]
    private let lock = NSLock()   // guards `slots` only

    private let backend: Backend

    init(backend: Backend) {
        self.backend = backend
    }

    private func slot(_ key: String) -> Slot {
        lock.withLock {
            if let slot = slots[key] { return slot }
            let slot = Slot()
            slots[key] = slot
            return slot
        }
    }

    /// Thread-safe read. Touches the Keychain only the first time a key is asked for.
    func get(_ key: String) -> String? {
        let slot = slot(key)
        return slot.lock.withLock {
            if !slot.loaded {
                slot.value = backend.load(key)
                slot.loaded = true
            }
            return slot.value
        }
    }

    /// Updates cache + persists to Keychain. Posts `.keychainValueChanged` when
    /// the value is new, so the service pollers fetch with it right away.
    func set(_ key: String, value: String) {
        let slot = slot(key)
        let changed = slot.lock.withLock { () -> Bool in
            let old = slot.loaded ? slot.value : backend.load(key)
            slot.value = value
            slot.loaded = true
            return old != value
        }
        backend.save(key, value)
        if changed { NotificationCenter.default.post(name: .keychainValueChanged, object: key) }
    }

    /// Removes from cache + Keychain only if the key holds a value (read first if not cached).
    func remove(_ key: String) {
        let slot = slot(key)
        let had = slot.lock.withLock { () -> Bool in
            let exists = slot.loaded ? slot.value != nil : backend.load(key) != nil
            slot.value = nil
            slot.loaded = true
            return exists
        }
        if had {
            backend.delete(key)
            NotificationCenter.default.post(name: .keychainValueChanged, object: key)
        }
    }
}
