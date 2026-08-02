import SwiftUI

struct MenuBarPopoverView: View {
    @EnvironmentObject private var usage: UsageRefreshCoordinator
    @EnvironmentObject private var taskStore: TaskStore
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var notifications: NotificationCoordinator
    @EnvironmentObject private var opener: SessionOpenerCoordinator
    @EnvironmentObject private var autoRun: QueueAutoRunCoordinator

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let opportunity = usage.burnOpportunity {
                burnBanner(opportunity)
            }
            Divider().padding(.vertical, 10)
            content
            if settingsStore.settings.queueEnabled {
                Divider().padding(.vertical, 10)
                autoRunBanner
                queueSummary
            }
            Divider().padding(.vertical, 10)
            footer
        }
        .padding(14)
        .frame(width: 330)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Tokenmax").font(.system(size: 14, weight: .semibold))
                Spacer()
                if let plan = usage.state.snapshot?.planName {
                    Text(plan)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
            }
            HStack(spacing: 5) {
                Text("Claude Code")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if usage.isStale, usage.state.snapshot != nil {
                    Text("· Stale")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }
            Text(usage.lastUpdatedText)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    /// The in-popover twin of the lit menubar icon, so the signal is explained
    /// the moment the user clicks through to find out what it means.
    ///
    /// Tinted with the same highlight colour rather than the accent colour: it
    /// is the *same* signal, and two colours for one signal is what makes a user
    /// wonder whether they are two.
    private func burnBanner(_ opportunity: BurnOpportunity) -> some View {
        let highlight = settingsStore.settings.menuBarHighlightColor.color

        return HStack(spacing: 7) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 11))
                .foregroundStyle(highlight)
            VStack(alignment: .leading, spacing: 1) {
                Text("Good time to spend quota")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(Int(opportunity.remainingPercent.rounded()))% left, resetting in \(RelativeTime.countdown(opportunity.timeUntilReset(now: usage.tick)))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(highlight.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        .padding(.top, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch usage.state {
        case .loading:
            statusBlock(
                icon: "arrow.triangle.2.circlepath",
                title: "Loading usage…",
                message: nil
            )

        case .claudeCodeNotInstalled:
            statusBlock(
                icon: "questionmark.folder",
                title: "Claude Code is not installed",
                message: "Tokenmax could not find the claude CLI on this Mac."
            )

        case .notAuthenticated:
            statusBlock(
                icon: "person.crop.circle.badge.exclamationmark",
                title: "Claude Code is not authenticated",
                message: "Run `claude` in a terminal and sign in, then refresh."
            )

        case .keychainAccessDenied:
            statusBlock(
                icon: "lock.trianglebadge.exclamationmark",
                title: "Keychain access denied",
                message: "Tokenmax needs to read the Claude Code credentials item to fetch usage. Click Refresh and choose Always Allow."
            )

        case let .tokenExpired(lastGood):
            VStack(alignment: .leading, spacing: 10) {
                statusBlock(
                    icon: "arrow.clockwise.circle",
                    title: "Waiting for Claude Code to refresh its token",
                    message: "The access token expired. Claude Code renews it the next time you run it — no sign-in needed."
                )
                if let lastGood {
                    windows(for: lastGood, forceStale: true)
                }
            }

        case .needsReauthentication:
            statusBlock(
                icon: "key.slash",
                title: "Claude Code needs re-authentication",
                message: "The stored credentials are gone and cannot be refreshed. Run `claude` and sign in again."
            )

        case let .unavailable(lastGood, message):
            VStack(alignment: .leading, spacing: 10) {
                statusBlock(
                    icon: "exclamationmark.triangle",
                    title: "Usage unavailable",
                    message: message
                )
                if let lastGood {
                    windows(for: lastGood, forceStale: true)
                }
            }

        case let .loaded(snapshot):
            if snapshot.windows.isEmpty {
                statusBlock(
                    icon: "chart.bar",
                    title: "No quota windows returned",
                    message: "Claude did not report any usage windows for this account."
                )
            } else {
                windows(for: snapshot, forceStale: usage.isStale)
            }
        }
    }

    private func windows(for snapshot: UsageSnapshot, forceStale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let session = snapshot.sessionWindow {
                VStack(alignment: .leading, spacing: 5) {
                    UsageWindowView(
                        window: session,
                        isStale: forceStale,
                        now: usage.tick,
                        projection: projection(for: session, forceStale: forceStale)
                    )
                    reminderLine(for: .session)
                    openerLine
                }
            }
            if let weekly = snapshot.weeklyWindow {
                VStack(alignment: .leading, spacing: 5) {
                    UsageWindowView(
                        window: weekly,
                        isStale: forceStale,
                        now: usage.tick,
                        projection: projection(for: weekly, forceStale: forceStale)
                    )
                    reminderLine(for: .weekly)
                }
            }
        }
    }

    /// A projection is a claim about what is happening *now*. Carrying the last
    /// good snapshot through a failure is worth doing for the numbers that were
    /// measured; extrapolating from them is not, so the pace line drops out with
    /// the rest of the live data rather than quietly ageing.
    private func projection(for window: UsageWindow, forceStale: Bool) -> UsageProjection? {
        forceStale ? nil : usage.projection(for: window)
    }

    /// Without this the scheduler's (correct) decision to stay silent is
    /// indistinguishable from the app being broken.
    @ViewBuilder
    private func reminderLine(for kind: UsageWindowKind) -> some View {
        if let status = notifications.statuses[kind] {
            HStack(spacing: 4) {
                Image(systemName: status.isSuppressed ? "bell.slash" : "bell")
                    .font(.system(size: 9))
                Text(status.summary(now: usage.tick))
                    .font(.system(size: 10))
            }
            .foregroundStyle(status.isNoteworthy ? Color.orange : Color.secondary)
        }
    }

    /// Only shown while the feature is on, and only for states the user would
    /// otherwise have to guess at — "a window is already running" is the normal
    /// case and says nothing worth the line.
    @ViewBuilder
    private var openerLine: some View {
        if settingsStore.settings.sessionOpener.enabled, let text = openerText {
            HStack(spacing: 4) {
                Image(systemName: "bolt.badge.clock")
                    .font(.system(size: 9))
                Text(text)
                    .font(.system(size: 10))
            }
            .foregroundStyle(openerIsNoteworthy ? Color.orange : Color.secondary)
        }
    }

    private var openerIsNoteworthy: Bool {
        opener.decision.skipReason?.isNoteworthy ?? false
    }

    private var openerText: String? {
        if opener.isRunning { return "Opening the next session…" }

        switch opener.decision.skipReason {
        case .none:
            return "Opener ready"
        case .windowAlreadyActive, .disabled, .noExpiredWindow:
            return nil
        case let .some(reason):
            return "Opener: \(reason.explanation)"
        }
    }

    private func statusBlock(icon: String, title: String, message: String?) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium))
                if let message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Queue

    /// The countdown is the one auto-run state that needs to be actionable from
    /// the menubar: it is the last chance to stop a run before it starts, and
    /// the popover is the fastest surface to reach.
    @ViewBuilder
    private var autoRunBanner: some View {
        if let pending = autoRun.pendingRun {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Starting a task in \(pending.secondsRemaining(now: usage.tick))s")
                            .font(.system(size: 11, weight: .semibold))
                        Text(pending.taskTitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    Button("Start Now") { autoRun.startPendingNow() }
                    Button("Cancel") { autoRun.cancelPending() }
                }
                .font(.system(size: 11))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            .padding(.bottom, 10)
        } else if let run = autoRun.activeRun {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Running \(run.taskTitle)")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(autoRun.progressText ?? "Working…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button("Stop") { autoRun.stop() }
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            .padding(.bottom, 10)
        } else if let text = autoRunStatusText {
            HStack(spacing: 4) {
                Image(systemName: "play.circle")
                    .font(.system(size: 9))
                Text(text)
                    .font(.system(size: 10))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(autoRun.decision.skipReason?.isNoteworthy == true ? Color.orange : Color.secondary)
            .padding(.bottom, 8)
        }
    }

    /// Silent on states the user need not act on, following the same rule as
    /// `openerLine`: a line that is always there stops being read.
    private var autoRunStatusText: String? {
        guard settingsStore.settings.queueAutoRun.enabled else { return nil }

        if autoRun.awaitingFreshUsage {
            return "Auto-run: waiting for a fresh quota reading."
        }

        switch autoRun.decision {
        case .preview:
            return "Auto-run preview: a task is eligible now."
        case .ask:
            return "Auto-run: a task is eligible and waiting for you."
        case .run:
            return "Auto-run: a task is eligible."
        case let .skip(reason):
            switch reason {
            case .disabled, .queueDisabled, .outsideLeadWindow, .noSessionWindow,
                 .noApprovedTask, .dataStale:
                return nil
            default:
                return "Auto-run: \(reason.explanation)"
            }
        }
    }

    private var queueSummary: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("QUEUE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)

            Text(summaryLine)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            ForEach(Array(taskStore.readyTasks.prefix(3).enumerated()), id: \.element.id) { index, task in
                HStack(spacing: 7) {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(task.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(task.priority.displayName)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            if taskStore.readyTasks.isEmpty {
                Text("No tasks queued. Add one so leftover quota has somewhere to go.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var summaryLine: String {
        "\(taskStore.readyCount) ready · \(taskStore.runningCount) running · \(taskStore.completedCount) completed"
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if settingsStore.settings.queueEnabled {
                Button("Open Queue") { openQueue() }
            }
            Button {
                Task { await usage.refresh(reason: "manual", manual: true) }
            } label: {
                if usage.isRefreshing {
                    Text("Refreshing…")
                } else {
                    Text("Refresh")
                }
            }
            .disabled(usage.isRefreshing)

            Spacer()

            Menu {
                Button("Settings…") { openWindow(id: TokenmaxWindow.settings) }
                Divider()
                Button("Quit Tokenmax") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func openQueue() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: TokenmaxWindow.queue)
    }
}
