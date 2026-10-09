import Combine
import Foundation

// MARK: - ServicePollGate
// The schedule and guards shared by the service pollers (Vercel, Resend, Stripe,
// Cal.com, Notion, n8n), the same rules GithubPoller follows:
// - no network while the service isn't wanted: its pill is off and the iPhone
//   sync is off (the iPhone shows every service, whatever is in the notch);
// - one poll at a time;
// - a response to a request sent with a key that has since changed is dropped
//   (the poll is handed a generation, checked with `isCurrent`);
// - turning the pill on or saving a new key polls right away instead of waiting
//   for the next tick.
// Everything but the timer runs on the main thread.

final class ServicePollGate: @unchecked Sendable {
    private let pillId: String
    private let keychainKeys: Set<String>
    private var timer: DispatchSourceTimer?
    private var poll: (@Sendable (_ generation: Int) async -> Void)?
    // All properties below are accessed only on the main thread.
    private var inFlight = false
    private var pollAgain = false
    private var pollQueued = false
    private var generation = 0
    private var pillObserver: AnyCancellable?
    private var keyObserver: NSObjectProtocol?

    init(pillId: String, keychainKeys: Set<String>) {
        self.pillId = pillId
        self.keychainKeys = keychainKeys
    }

    /// The service's data is fetched when its pill is in the notch, or when the
    /// iPhone sync is on.
    @MainActor static func isWanted(_ pillId: String) -> Bool {
        if AppState.shared.activeIntegrations.contains(pillId) { return true }
        #if PHONE_LINK
        return UserDefaults.standard.bool(forKey: "iPhoneSyncEnabled")
        #else
        return false
        #endif
    }

    /// Starts the timer (first tick after `delay`, then every `interval`) and
    /// the prompt polls. `poll` runs off the main thread; the gate counts it as
    /// in flight until it returns.
    @MainActor
    func start(after delay: Double, every interval: Double,
               poll: @escaping @Sendable (_ generation: Int) async -> Void) {
        guard timer == nil else { return }
        self.poll = poll
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + delay, repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t

        // @Published sends the new value before it is stored: queuePoll checks
        // isWanted on the next turn of the main queue, once it is.
        let pillId = pillId
        pillObserver = AppState.shared.$activeIntegrations
            .map { $0.contains(pillId) }
            .removeDuplicates()
            .dropFirst()
            .filter { $0 }
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.queuePoll() }
            }

        let keys = keychainKeys
        keyObserver = NotificationCenter.default.addObserver(
            forName: .keychainValueChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let key = note.object as? String, keys.contains(key) else { return }
            MainActor.assumeIsolated { self?.keyChanged() }
        }
    }

    /// Polls now (Refresh button), unless the service isn't wanted. If a poll is
    /// already in flight, another one follows it. Safe from any thread.
    func pollNow() {
        DispatchQueue.main.async { [weak self] in self?.queuePoll() }
    }

    /// True when a poll started with `generation` still matches the saved key.
    @MainActor func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation
    }

    // MARK: - Private

    private func tick() {
        guard !DemoEngine.isPollerPaused else { return }
        DispatchQueue.main.async { [weak self] in self?.runIfWanted() }
    }

    @MainActor private func keyChanged() {
        generation += 1
        queuePoll()
    }

    /// Coalesces the prompt polls asked in the same turn of the main queue
    /// (n8n saves its URL and its key together).
    @MainActor private func queuePoll() {
        guard !pollQueued else { return }
        pollQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pollQueued = false
            if self.inFlight { self.pollAgain = true } else { self.runIfWanted() }
        }
    }

    @MainActor private func runIfWanted() {
        guard !inFlight, !DemoEngine.isPollerPaused, let poll, Self.isWanted(pillId) else { return }
        inFlight = true
        let current = generation
        Task.detached(priority: .background) { [weak self] in
            await poll(current)
            DispatchQueue.main.async { self?.finish() }
        }
    }

    @MainActor private func finish() {
        inFlight = false
        if pollAgain {
            pollAgain = false
            runIfWanted()
        }
    }

    // MARK: - HTTP

    /// URLSession's completion-handler result, awaited: the body, the HTTP
    /// status (0 when there is no response) and the transport error.
    static func load(_ request: URLRequest) async -> (data: Data?, code: Int, error: Error?) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0, nil)
        } catch {
            return (nil, 0, error)
        }
    }
}

extension Notification.Name {
    /// Posted by KeychainStore when a key's value changes; the object is the key name.
    static let keychainValueChanged = Notification.Name("coucou.keychainValueChanged")
}
