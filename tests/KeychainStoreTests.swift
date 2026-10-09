import Foundation

// KeychainStore's cache over a fake backend (the real Keychain is never touched):
// lazy reads, at most one read per key, set/remove and their notifications, any key name,
// many threads at once.

extension Notification.Name {
    // Declared in ServicePollGate.swift in the app.
    static let keychainValueChanged = Notification.Name("coucou.keychainValueChanged")
}

/// An in-memory Keychain that counts its reads.
final class FakeKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String]
    private var reads: [String: Int] = [:]
    /// Keys whose reads fail (a locked Keychain) until cleared.
    var failing: Set<String> {
        get { lock.withLock { _failing } }
        set { lock.withLock { _failing = newValue } }
    }
    private var _failing: Set<String> = []
    private(set) var saves = 0
    private(set) var deletes = 0

    init(_ items: [String: String]) { self.items = items }

    func readCount(_ key: String) -> Int { lock.withLock { reads[key, default: 0] } }
    func stored(_ key: String) -> String? { lock.withLock { items[key] } }

    var backend: KeychainStore.Backend {
        KeychainStore.Backend(
            load: { key in
                Thread.sleep(forTimeInterval: 0.002)   // a slow read widens any race
                return self.lock.withLock {
                    self.reads[key, default: 0] += 1
                    if self._failing.contains(key) { return .failed }
                    return self.items[key].map(KeychainRead.value) ?? .missing
                }
            },
            save: { key, value in self.lock.withLock { self.saves += 1; self.items[key] = value } },
            delete: { key in self.lock.withLock { self.deletes += 1; self.items[key] = nil } })
    }
}

@main
enum KeychainStoreTests {

    nonisolated(unsafe) static var failures = 0

    static func check(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") } else { print("  ✗ \(label)"); failures += 1 }
    }

    /// The keys posted with `.keychainValueChanged` while `body` runs.
    static func posted(_ body: () -> Void) -> [String] {
        final class Box: @unchecked Sendable { var keys: [String] = [] }
        let box = Box()
        let token = NotificationCenter.default.addObserver(forName: .keychainValueChanged, object: nil, queue: nil) {
            if let key = $0.object as? String { box.keys.append(key) }
        }
        body()
        NotificationCenter.default.removeObserver(token)
        return box.keys
    }

    static func main() {
        print("KeychainStore — lazy, one read per key")
        do {
            let fake = FakeKeychain(["github-token": "ghp_1"])
            let store = KeychainStore(backend: fake.backend)
            check("nothing read up front", fake.readCount("github-token") == 0)
            check("first get reads the Keychain", store.get("github-token") == "ghp_1" && fake.readCount("github-token") == 1)
            check("second get is cached", store.get("github-token") == "ghp_1" && fake.readCount("github-token") == 1)
            check("missing key: nil, read once", store.get("vercel-token") == nil && store.get("vercel-token") == nil
                  && fake.readCount("vercel-token") == 1)
            check("other keys untouched", fake.readCount("stripe-api-key") == 0)
        }

        print("KeychainStore — a failed read is not cached")
        do {
            let fake = FakeKeychain(["github-token": "ghp_1"])
            fake.failing = ["github-token"]
            let store = KeychainStore(backend: fake.backend)
            check("failed read: nil", store.get("github-token") == nil && fake.readCount("github-token") == 1)
            fake.failing = []
            check("next get reads again and finds it", store.get("github-token") == "ghp_1"
                  && fake.readCount("github-token") == 2)
            check("then cached", store.get("github-token") == "ghp_1" && fake.readCount("github-token") == 2)
        }

        print("KeychainStore — any key name works")
        do {
            let fake = FakeKeychain(["some-future-key": "v"])
            let store = KeychainStore(backend: fake.backend)
            check("unlisted key is read", store.get("some-future-key") == "v")
            store.set("another-new-key", value: "w")
            check("unlisted key set, then read from cache", store.get("another-new-key") == "w"
                  && fake.stored("another-new-key") == "w")
        }

        print("KeychainStore — set")
        do {
            let fake = FakeKeychain(["n8n-url": "https://a"])
            let store = KeychainStore(backend: fake.backend)
            var keys = posted { store.set("n8n-url", value: "https://a") }
            check("same value as the Keychain (not cached yet): no notification", keys.isEmpty)
            check("…saved anyway, as before", fake.saves == 1)
            keys = posted { store.set("n8n-url", value: "https://b") }
            check("new value: notification with the key", keys == ["n8n-url"])
            check("cached: no further read", store.get("n8n-url") == "https://b" && fake.readCount("n8n-url") == 1)
            keys = posted { store.set("resend-from", value: "me@x.fr") }
            check("first value of a missing key: notification", keys == ["resend-from"])
        }

        print("KeychainStore — remove")
        do {
            let fake = FakeKeychain(["stripe-api-key": "sk", "calcom-api-key": "cal"])
            let store = KeychainStore(backend: fake.backend)
            var keys = posted { store.remove("notion-api-key") }
            check("absent key: no delete, no notification", keys.isEmpty && fake.deletes == 0)
            keys = posted { store.remove("stripe-api-key") }
            check("uncached key with a value: deleted, notified", keys == ["stripe-api-key"] && fake.stored("stripe-api-key") == nil)
            _ = store.get("calcom-api-key")
            keys = posted { store.remove("calcom-api-key") }
            check("cached key: deleted, notified", keys == ["calcom-api-key"] && fake.deletes == 2)
            let reads = fake.readCount("calcom-api-key")
            check("after remove: nil from cache, no read", store.get("calcom-api-key") == nil && fake.readCount("calcom-api-key") == reads)
            keys = posted { store.remove("calcom-api-key") }
            check("removing twice: second is a no-op", keys.isEmpty && fake.deletes == 2)
        }

        print("KeychainStore — many threads")
        do {
            let fake = FakeKeychain(["k0": "v0", "k1": "v1", "k2": "v2", "k3": "v3"])
            let store = KeychainStore(backend: fake.backend)
            final class Box: @unchecked Sendable { let lock = NSLock(); var wrong = 0 }
            let box = Box()
            DispatchQueue.concurrentPerform(iterations: 400) { i in
                let key = "k\(i % 4)"
                if store.get(key) != "v\(i % 4)" { box.lock.withLock { box.wrong += 1 } }
            }
            check("every reader got its value", box.wrong == 0)
            check("each key read exactly once", (0..<4).allSatisfy { fake.readCount("k\($0)") == 1 })
        }

        if failures == 0 { print("\nAll tests passed."); exit(0) }
        print("\n\(failures) test(s) failed."); exit(1)
    }
}
