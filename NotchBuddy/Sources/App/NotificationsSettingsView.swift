import SwiftUI
import AppKit
import UserNotifications

// MARK: - NotificationsSettingsView

/// "Notifications" section inside SettingsView: macOS banners for agent sessions.
struct NotificationsSettingsView: View {
    @ObservedObject private var notifier = MacNotifier.shared

    @AppStorage(NotificationSettings.enabledKey, store: AppDefaults.store)  private var enabled  = true
    @AppStorage(NotificationSettings.finishedKey, store: AppDefaults.store) private var finished = true
    @AppStorage(NotificationSettings.errorsKey, store: AppDefaults.store)   private var errors   = true
    @AppStorage(NotificationSettings.waitingKey, store: AppDefaults.store)  private var waiting  = true
    @AppStorage(NotificationSettings.stalledKey, store: AppDefaults.store)  private var stalled  = true
    @AppStorage(NotificationSettings.stallThresholdKey, store: AppDefaults.store)
    private var stallMinutes = NotificationSettings.defaultStallMinutes

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            bannersSection
            stallSection
        }
        .onAppear { notifier.refreshAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            notifier.refreshAuthorization()
        }
    }

    // MARK: - Banners

    private var bannersSection: some View {
        GroupBox(String(localized: "macOS notifications")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(String(localized: "Show macOS notifications"), isOn: $enabled)
                    .onChange(of: enabled) { _, on in
                        if on && notifier.authorization == .notDetermined { notifier.requestAuthorization() }
                    }
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(String(localized: "When an agent finishes"), isOn: $finished)
                    Toggle(String(localized: "When an agent hits an error"), isOn: $errors)
                    Toggle(String(localized: "When an agent needs your OK or asks a question"), isOn: $waiting)
                    Toggle(String(localized: "When an agent seems stuck"), isOn: $stalled)
                }
                .padding(.leading, 18)
                .disabled(!enabled)
                Text(String(localized: "Only when you can't already see it: no banner while the app the agent runs in is in front, or while the island shows that pill. Silent: Coucou plays its own sounds."))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                authorizationRow
            }
            .padding(6)
        }
    }

    @ViewBuilder private var authorizationRow: some View {
        switch notifier.authorization {
        case .denied:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(String(localized: "Notifications for Coucou are turned off in System Settings."))
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(String(localized: "Open System Settings")) { notifier.openSystemSettings() }
                    .controlSize(.small)
            }
        case .notDetermined:
            HStack(spacing: 8) {
                Text(String(localized: "macOS asks for permission the first time Coucou shows a notification."))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(String(localized: "Allow notifications")) { notifier.requestAuthorization() }
                    .controlSize(.small)
                    .disabled(!enabled)
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Stalls

    private var stallSection: some View {
        GroupBox(String(localized: "Stuck sessions")) {
            VStack(alignment: .leading, spacing: 10) {
                Picker(String(localized: "Flag a working session after"), selection: $stallMinutes) {
                    ForEach(NotificationSettings.stallMinuteChoices, id: \.self) { minutes in
                        if minutes == 0 {
                            Text(String(localized: "Off")).tag(0)
                        } else {
                            Text(String(localized: "\(minutes) min without activity")).tag(minutes)
                        }
                    }
                }
                .frame(maxWidth: 360)
                .onChange(of: stallMinutes) { _, _ in StallMonitor.shared.refresh() }
                Text(String(localized: "A session that stops sending events while working gets an hourglass on its pill. Sessions waiting on you are never flagged."))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }
}
