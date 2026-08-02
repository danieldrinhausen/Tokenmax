import AppKit
import Combine
import UserNotifications

/// Wires usage refreshes to notification scheduling, and handles taps on the
/// banner's action buttons.
@MainActor
final class NotificationCoordinator: NSObject, ObservableObject {
    private let manager: NotificationManager
    private let usage: UsageRefreshCoordinator
    private let taskStore: TaskStore
    private let settingsStore: SettingsStore

    /// Per-window reminder status, surfaced in the popover and Settings.
    @Published private(set) var statuses: [UsageWindowKind: ReminderStatus] = [:]

    private var state: NotificationState
    private var settingsCancellable: AnyCancellable?
    private var queueEnabledCancellable: AnyCancellable?
    private var tasksCancellable: AnyCancellable?
    private var isSyncing = false
    private var hasStarted = false

    init(
        manager: NotificationManager,
        usage: UsageRefreshCoordinator,
        taskStore: TaskStore,
        settingsStore: SettingsStore
    ) {
        self.manager = manager
        self.usage = usage
        self.taskStore = taskStore
        self.settingsStore = settingsStore
        state = JSONStore.load(NotificationState.self, from: FileLocations.notificationStateFile)
            ?? NotificationState()
        super.init()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        manager.registerCategories(delegate: self)
        manager.updateCategories(queueEnabled: settingsStore.settings.queueEnabled)

        NotificationCenter.default.addObserver(
            forName: .tokenmaxUsageUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.syncScheduledNotifications() }
        }

        // A settings change must take effect immediately — otherwise the user
        // adjusts a reminder and sees nothing happen until the next refresh.
        settingsCancellable = settingsStore.$settings
            .removeDuplicates()
            // `@Published` republishes its current value on subscribe; without
            // dropping it this races the explicit initial sync below and can
            // deliver the same reminder twice.
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in await self?.syncScheduledNotifications() }
            }

        // Separate from the sync above: the banner's action buttons are baked
        // into the registered category, not into the request, so switching the
        // queue off has to re-register or delivered banners keep offering it.
        queueEnabledCancellable = settingsStore.$settings
            .map(\.queueEnabled)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in
                Task { @MainActor in self?.manager.updateCategories(queueEnabled: enabled) }
            }

        // The banner quotes the queued-task count and the queue-empty guard
        // depends on it, so queue edits have to re-issue the pending reminder.
        tasksCancellable = taskStore.$tasks
            .map { $0.filter { task in task.status == .ready }.count }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in await self?.syncScheduledNotifications() }
            }

        Task { await syncScheduledNotifications() }
    }

    /// Clears the fired record for the window currently in effect so the
    /// reminder can be delivered again. Backs the "Send Again" button.
    func rearmCurrentWindow(_ kind: UsageWindowKind) async {
        guard let window = usage.state.snapshot?.window(kind), let resetAt = window.resetAt else { return }
        let identifier = NotificationScheduler.identifier(for: kind, resetAt: resetAt)

        state.clearFired(identifier)
        persistState()
        Log.shared.write("notify: re-armed \(identifier)")

        await syncScheduledNotifications()
    }

    /// Recomputes every reminder from the current snapshot. Idempotent — safe to
    /// call after every refresh, which is exactly what happens.
    func syncScheduledNotifications() async {
        // The body awaits, so two overlapping syncs could both observe
        // `alreadyFired == false` and each send the reminder.
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let settings = settingsStore.settings
        let queuedCount = taskStore.readyCount

        // There may still be a pending request from the last good snapshot.
        // Keep it while a transient refresh failure makes the data stale, but
        // remove it when reminders were explicitly disabled. Returning here
        // without applying a decision used to leave stale notifications alive
        // after credentials disappeared or the app lost its snapshot entirely.
        guard let snapshot = usage.state.snapshot else {
            let reason: SchedulingDecision.SkipReason = settings.remindersEnabled
                ? .noSnapshot
                : .remindersDisabled
            for kind in [UsageWindowKind.session, .weekly] {
                let decision = SchedulingDecision.skip(reason: reason)
                await NotificationScheduler.apply(
                    decision,
                    kind: kind,
                    playSound: settings.playSound
                )
                statuses[kind] = ReminderStatus(decision: decision)
            }
            updateBadge(count: 0)
            return
        }
        let stale = usage.isStale

        for kind in [UsageWindowKind.session, .weekly] {
            guard let window = snapshot.window(kind) else {
                let decision = SchedulingDecision.skip(reason: .noResetTime)
                await NotificationScheduler.apply(
                    decision,
                    kind: kind,
                    playSound: settings.playSound
                )
                statuses[kind] = ReminderStatus(decision: decision)
                continue
            }

            let rule = kind == .session ? settings.sessionReminder : settings.weeklyReminder
            let windowIdentifier = window.resetAt.map {
                NotificationScheduler.identifier(for: kind, resetAt: $0)
            }
            let alreadyFired = windowIdentifier.map {
                state.hasFired($0, fingerprint: rule.fingerprint)
            } ?? false

            let decision = NotificationScheduler.decide(.init(
                window: window,
                rule: rule,
                remindersEnabled: settings.remindersEnabled,
                quietHours: settings.quietHours,
                isStale: stale,
                queuedTaskCount: queuedCount,
                queueEnabled: settings.queueEnabled,
                alreadyFired: alreadyFired,
                now: Date()
            ))

            let deliveredNow = await NotificationScheduler.apply(
                decision,
                kind: kind,
                playSound: settings.playSound
            )

            // An immediately-delivered reminder has no pending request to dedup
            // against, so record it here or every refresh would send another.
            if let deliveredNow {
                state.markFired(deliveredNow, fingerprint: rule.fingerprint)
                persistState()
            }

            statuses[kind] = ReminderStatus(
                decision: decision,
                firedAt: windowIdentifier.flatMap { state.firedAt($0) }
            )
        }

        // The badge counts queued tasks, so it has nothing to say once the queue
        // is switched off.
        if settings.showBadge, settings.queueEnabled {
            updateBadge(count: queuedCount)
        } else {
            updateBadge(count: 0)
        }
    }

    private func updateBadge(count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    private func persistState() {
        JSONStore.save(state, to: FileLocations.notificationStateFile)
    }

    /// Records a reminder that the system delivered while the app was running.
    ///
    /// The fingerprint has to be stored here too. A record written without one
    /// looks exactly like a pre-fingerprint file to `hasFired`, which would
    /// re-arm the window and send the reminder a second time.
    private func recordFired(identifier: String) {
        // Snoozed copies carry a `-snooze-N` suffix; the window is the base.
        let base = identifier.components(separatedBy: "-snooze-").first ?? identifier
        let isWeekly = base.hasPrefix(NotificationScheduler.identifierPrefix(for: .weekly))
        let rule = isWeekly ? settingsStore.settings.weeklyReminder : settingsStore.settings.sessionReminder

        state.markFired(base, fingerprint: rule.fingerprint)
        persistState()
    }

    // MARK: - Actions

    /// Tapping the banner body routes here too, and the queue can be switched
    /// off between scheduling and delivery — so the guard lives here rather than
    /// only on the buttons that offer it.
    private func openQueue() {
        NSApp.activate(ignoringOtherApps: true)
        guard settingsStore.settings.queueEnabled else { return }
        NotificationCenter.default.post(name: .tokenmaxOpenQueue, object: nil)
    }

    /// 0.1 behaviour: prepare, never execute. Copies the top ready task's prompt
    /// and opens the queue so the user can start it themselves.
    private func startManualSession() {
        openQueue()
        guard settingsStore.settings.queueEnabled, let task = taskStore.readyTasks.first else { return }
        ManualRunService.copyPrompt(task)
        Log.shared.write("notify: Start Manual Session copied prompt for '\(task.title)'")
    }

    private func snooze(_ payload: NotificationSnoozePayload) async {
        let original = payload.identifier
        let baseIdentifier = original.components(separatedBy: "-snooze-").first ?? original
        let count = (state.snoozeCounts[baseIdentifier] ?? 0) + 1
        state.snoozeCounts[baseIdentifier] = count
        persistState()

        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.categoryIdentifier = NotificationManager.categoryIdentifier
        if let windowKind = payload.windowKind {
            content.userInfo = ["windowKind": windowKind]
        }
        if settingsStore.settings.playSound { content.sound = .default }
        NotificationIcon.attach(to: content)

        let request = UNNotificationRequest(
            identifier: "\(baseIdentifier)-snooze-\(count)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 15 * 60, repeats: false)
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            Log.shared.write("notify: snoozed \(baseIdentifier) (#\(count)) for 15m")
        } catch {
            Log.shared.write("notify: snooze failed: \(error.localizedDescription)")
        }
    }
}

extension NotificationCoordinator: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let identifier = notification.request.identifier
        // The delegate callback is nonisolated; extract the value before the
        // actor hop instead of capturing the non-Sendable notification object.
        Task { @MainActor [weak self] in
            self?.recordFired(identifier: identifier)
        }
        // The system callback must be completed independently of the main actor.
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let request = response.notification.request
        let identifier = request.identifier
        let content = request.content
        let snoozePayload = NotificationSnoozePayload(
            identifier: identifier,
            title: content.title,
            body: content.body,
            windowKind: content.userInfo["windowKind"] as? String
        )

        // Complete the OS callback now. The actual app action is serialized on
        // the main actor and cannot delay delivery acknowledgement.
        completionHandler()

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.recordFired(identifier: identifier)

            switch action {
            case NotificationManager.Action.openQueue,
                 UNNotificationDefaultActionIdentifier:
                self.openQueue()
            case NotificationManager.Action.startManual:
                self.startManualSession()
            case NotificationManager.Action.snooze15:
                await self.snooze(snoozePayload)

            case AutoRunNotifier.Action.startNow:
                NotificationCenter.default.post(name: .tokenmaxAutoRunStartNow, object: nil)
            case AutoRunNotifier.Action.cancel:
                NotificationCenter.default.post(name: .tokenmaxAutoRunCancel, object: nil)
            case AutoRunNotifier.Action.viewOutput:
                NotificationCenter.default.post(name: .tokenmaxAutoRunViewOutput, object: nil)
            case AutoRunNotifier.Action.openQueue:
                self.openQueue()

            default:
                break
            }

            Log.shared.write("notify: action=\(action)")
        }
    }
}

private struct NotificationSnoozePayload: Sendable {
    let identifier: String
    let title: String
    let body: String
    let windowKind: String?
}

