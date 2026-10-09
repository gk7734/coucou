import AppKit
import Combine
import UserNotifications

// MARK: - MacNotifier
//
// Shows SessionAlerts as macOS Notification Center banners (NotificationPolicy decides
// which), and opens the island on the pill when one is clicked.
//
// - One banner per session (request identifier per session): a newer alert replaces it,
//   and a banner that waited on the user goes away once the session moves on.
// - No sound: Coucou already plays its own for these events, and its sound setting is
//   the only one the user has to think about.
// - No action buttons: a permission is only ever approved by a click in Coucou's own UI.
// - Authorization is asked the first time a banner would show, or from Settings.

@MainActor
final class MacNotifier: NSObject, ObservableObject {
    static let shared = MacNotifier()

    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined

    private var ledger = NotificationLedger()
    /// Banners on screen that can go out of date, by request identifier.
    private var delivered: [String: NotificationPolicy.Delivered] = [:]
    private var booksObserver: ChangeObserver<[String: SessionBook]>?
    private var started = false

    private var center: UNUserNotificationCenter { .current() }

    private override init() { super.init() }

    /// Called once at launch: becomes the notification delegate (so clicks reach Coucou)
    /// and the SessionAlertCenter's outlet.
    func start() {
        guard !started else { return }
        started = true
        center.delegate = self
        SessionAlertCenter.shared.deliver = { [weak self] alert in self?.handle(alert) }
        refreshAuthorization()
        booksObserver = ChangeObserver({ AppState.shared.sessionBooks }, initial: true) { [weak self] books in
            self?.removeOutdated(books: books)
        }
    }

    // MARK: Alerts

    private func handle(_ alert: SessionAlert) {
        let state = AppState.shared
        let task = state.tasks.first { $0.id == alert.pillId }
        var alert = alert
        if (alert.hostBundleId ?? "").isEmpty { alert.hostBundleId = task?.sessionBundleId }

        let now = Date()
        let names = NotificationNames(
            hostName: alert.hostBundleId.flatMap { $0.isEmpty ? nil : HostAppInfo.name(for: $0) },
            pillName: PillCatalog.definition(for: alert.pillId)?.name ?? task?.name ?? "")
        let context = NotificationContext(
            frontmostBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            islandPillId: state.mode == .expanded ? state.focusId : nil,
            now: now)
        let decision = NotificationPolicy.decide(alert, settings: NotificationSettings(defaults: .standard),
                                                 context: context, names: names, ledger: ledger)
        let id = NotificationPolicy.identifier(pillId: alert.pillId, sessionId: alert.sessionId)
        switch decision {
        case .show(let plan):
            ledger.record(alert, now: now)
            let banner = NotificationPolicy.Delivered(
                pillId: alert.pillId, sessionId: alert.sessionId, kind: alert.kind, deliveredAt: now,
                lastEventAt: state.sessionBooks[alert.pillId]?.session(alert.sessionId)?.lastEventAt)
            show(plan, alert: alert, banner: banner)
        case .skip:
            if decision.clearsPrevious { remove([id]) }
        }
    }

    private func show(_ plan: NotificationPlan, alert: SessionAlert, banner: NotificationPolicy.Delivered) {
        withAuthorization { [weak self] granted in
            guard let self, granted else { return }
            let content = UNMutableNotificationContent()
            content.title = plan.title
            content.body = plan.body
            content.threadIdentifier = plan.threadId
            content.sound = nil
            content.userInfo = [
                "pillId": alert.pillId,
                "sessionId": alert.sessionId,
                "kind": alert.kind.rawValue,
                "hostBundleId": alert.hostBundleId ?? "",
            ]
            // A request with the same identifier would update the old banner silently in
            // Notification Center; removing it first makes the new one show as a banner.
            self.center.removeDeliveredNotifications(withIdentifiers: [plan.identifier])
            self.center.add(UNNotificationRequest(identifier: plan.identifier, content: content, trigger: nil))
            // Finished / error banners never go out of date; the others are watched.
            let watched = banner.kind != .finished && banner.kind != .error
            self.delivered[plan.identifier] = watched ? banner : nil
        }
    }

    private func remove(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        for id in ids { delivered[id] = nil }
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    private func removeOutdated(books: [String: SessionBook]) {
        guard !delivered.isEmpty else { return }
        remove(NotificationPolicy.outdated(delivered, books: books, now: Date()))
    }

    // MARK: Authorization

    /// Re-reads the authorization (Settings shows it; the user may change it in System Settings).
    func refreshAuthorization() {
        center.getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in MacNotifier.shared.authorization = status }
        }
    }

    /// Asks macOS once; afterwards only System Settings can change the answer.
    func requestAuthorization(then done: (@MainActor (Bool) -> Void)? = nil) {
        center.requestAuthorization(options: [.alert]) { granted, _ in
            Task { @MainActor in
                MacNotifier.shared.refreshAuthorization()
                done?(granted)
            }
        }
    }

    private func withAuthorization(_ body: @escaping @MainActor (Bool) -> Void) {
        center.getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                MacNotifier.shared.authorization = status
                switch status {
                case .notDetermined: MacNotifier.shared.requestAuthorization(then: body)
                case .denied:        body(false)
                default:             body(true)
                }
            }
        }
    }

    /// System Settings → Notifications → Coucou.
    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        let urls = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)",
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: Click

    /// A banner was clicked: bring its app forward and open the island on its pill, the
    /// way an alert opens it (.hookExpand). Never approves anything.
    private func open(pillId: String, kind: SessionAlert.Kind?, hostBundleId: String) {
        let state = AppState.shared
        if !hostBundleId.isEmpty { HostAppInfo.activate(hostBundleId) }
        guard state.tasks.contains(where: { $0.id == pillId }) else { return }
        state.setFocus(pillId)
        state.cardSelection = nil
        let view: IslandView
        if kind == .waitingApproval, state.pendingApproval?.pillId == pillId {
            view = .approval
        } else if kind == .waitingAnswer, state.pendingQuestion != nil {
            view = .question
        } else {
            view = .overview
        }
        NotificationCenter.default.post(name: .hookExpand, object: view)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension MacNotifier: UNUserNotificationCenterDelegate {
    /// Coucou is active while Settings is open: show the banner anyway.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let isOpen = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let pillId = info["pillId"] as? String ?? ""
        let kind = (info["kind"] as? String).flatMap(SessionAlert.Kind.init(rawValue:))
        let host = info["hostBundleId"] as? String ?? ""
        completionHandler()
        guard isOpen, !pillId.isEmpty else { return }
        Task { @MainActor in
            MacNotifier.shared.open(pillId: pillId, kind: kind, hostBundleId: host)
        }
    }
}
