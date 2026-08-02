import AppKit
import UserNotifications

enum NotificationAuthState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case provisional
}

/// Owns authorization and category registration.
///
/// Authorization is requested **only** when the user turns reminders on — never
/// at launch, per the spec.
@MainActor
final class NotificationManager: ObservableObject {
    nonisolated static let categoryIdentifier = "TOKENMAX_QUOTA_REMINDER"

    enum Action {
        static let openQueue = "TOKENMAX_OPEN_QUEUE"
        static let startManual = "TOKENMAX_START_MANUAL"
        static let snooze15 = "TOKENMAX_SNOOZE_15"
    }

    @Published private(set) var authState: NotificationAuthState = .notDetermined

    private let center = UNUserNotificationCenter.current()

    func registerCategories(delegate: UNUserNotificationCenterDelegate) {
        center.delegate = delegate
        Task { await refreshAuthState() }
    }

    /// Called again whenever the queue setting changes — a banner must never
    /// offer "Open Queue" for a feature that is switched off. Registration
    /// replaces the category wholesale, so this is safe to repeat.
    func updateCategories(queueEnabled: Bool) {
        var actions: [UNNotificationAction] = []

        if queueEnabled {
            actions.append(UNNotificationAction(
                identifier: Action.openQueue,
                title: "Open Queue",
                options: [.foreground]
            ))
            actions.append(UNNotificationAction(
                identifier: Action.startManual,
                title: "Start Manual Session",
                options: [.foreground]
            ))
        }

        actions.append(UNNotificationAction(
            identifier: Action.snooze15,
            title: "Snooze 15 Minutes",
            options: []
        ))

        let reminder = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )

        // Registration *replaces* the whole set rather than adding to it, so
        // both categories have to be passed every time. Passing only one here
        // silently strips the other's buttons from every delivered banner.
        center.setNotificationCategories([reminder, Self.autoRunCategory])
    }

    /// The auto-runner's actions. Deliberately a separate category from the
    /// quota reminder — see `AutoRunNotifier`.
    ///
    /// Not gated on `queueEnabled` the way the reminder's actions are: the
    /// auto-runner cannot produce a banner at all while the queue is off, so
    /// there is no state in which these appear without something to act on.
    private static var autoRunCategory: UNNotificationCategory {
        UNNotificationCategory(
            identifier: AutoRunNotifier.categoryIdentifier,
            actions: [
                UNNotificationAction(
                    identifier: AutoRunNotifier.Action.startNow,
                    title: "Start Now",
                    options: [.foreground]
                ),
                UNNotificationAction(
                    identifier: AutoRunNotifier.Action.cancel,
                    title: "Cancel",
                    options: []
                ),
                UNNotificationAction(
                    identifier: AutoRunNotifier.Action.viewOutput,
                    title: "View Output",
                    options: [.foreground]
                ),
                UNNotificationAction(
                    identifier: AutoRunNotifier.Action.openQueue,
                    title: "Open Queue",
                    options: [.foreground]
                ),
            ],
            intentIdentifiers: [],
            options: []
        )
    }

    func refreshAuthState() async {
        let settings = await center.notificationSettings()
        authState = Self.map(settings.authorizationStatus)
    }

    /// Returns whether reminders can actually be delivered.
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthState()
            Log.shared.write("notifications: authorization granted=\(granted)")
            return granted
        } catch {
            Log.shared.write("notifications: authorization failed: \(error.localizedDescription)")
            await refreshAuthState()
            return false
        }
    }

    func openSystemNotificationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
        NSWorkspace.shared.open(url)
    }

    private static func map(_ status: UNAuthorizationStatus) -> NotificationAuthState {
        switch status {
        case .authorized: .authorized
        case .denied: .denied
        case .provisional: .provisional
        default: .notDetermined
        }
    }
}
