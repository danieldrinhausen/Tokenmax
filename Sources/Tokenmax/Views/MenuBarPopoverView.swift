import SwiftUI

struct MenuBarPopoverView: View {
    @EnvironmentObject private var usage: ProviderUsageCoordinator
    @EnvironmentObject private var taskStore: TaskStore
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var notifications: NotificationCoordinator
    @EnvironmentObject private var opener: SessionOpenerCoordinator
    @EnvironmentObject private var autoRun: QueueAutoRunCoordinator
    @EnvironmentObject private var updates: UpdateCheckCoordinator

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            appHeader
            if let opportunity = usage.burnOpportunity {
                burnBanner(opportunity)
            }
            // A switched-off provider loses its section *and* the divider above
            // it — leaving the rule behind would read as an empty section.
            ForEach(settingsStore.settings.enabledProviders) { provider in
                Divider().padding(.vertical, 10)
                providerSection(for: provider)
            }
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

    /// The app's own header, and nothing else. Everything that describes one
    /// provider — its plan, its freshness, its age — belongs to that provider's
    /// section, or the first provider silently inherits the title position and
    /// the second looks like a subsection of the first.
    private var appHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Tokenmax").font(.system(size: 14, weight: .semibold))
            // Beside the name rather than in an About box alone: the first
            // thing anyone needs when reporting a problem is which build they
            // are on, and the popover is the one surface always a click away.
            Text(AppInfo.version)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let version = updates.availableVersion, let page = updates.releasePage {
                Link(destination: page) {
                    Label("\(version.description) available", systemImage: "arrow.down.circle")
                        .font(.caption)
                }
                .help("Open the release page on GitHub")
            }
        }
    }

    // MARK: - Provider sections

    /// Every provider renders through here, so the layout cannot drift apart
    /// between them: same header, same freshness line, same window rows.
    private func providerSection(for provider: TokenmaxProvider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            providerHeader(for: provider)
            providerContent(for: provider)
        }
    }

    private func providerHeader(for provider: TokenmaxProvider) -> some View {
        let coordinator = usage.coordinator(for: provider)
        let snapshot = coordinator.state.snapshot

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(provider.displayName)
                    .font(.system(size: 12, weight: .semibold))
                if usage.isStale(for: provider), snapshot != nil {
                    Text("· Stale")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                    // The fix for staleness is one click, so offer it where the
                    // staleness is announced rather than in the footer.
                    Button("Refresh") { perform(.refresh, provider: provider) }
                        .font(.system(size: 10))
                        .buttonStyle(.link)
                        .disabled(coordinator.isRefreshing)
                }
                Spacer(minLength: 0)
                if let plan = snapshot?.planName {
                    Text(plan)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
            }
            Text(coordinator.lastUpdatedText)
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
    private func providerContent(for provider: TokenmaxProvider) -> some View {
        switch usage.state(for: provider) {
        case .loading:
            statusBlock(
                icon: "arrow.triangle.2.circlepath",
                title: "Loading usage…",
                message: nil
            )

        case .claudeCodeNotInstalled:
            statusBlock(
                icon: "questionmark.folder",
                title: "\(provider.displayName) is not installed",
                message: "Tokenmax could not find the \(provider.commandName) CLI on this Mac.",
                recovery: [.openTerminal, .refresh],
                provider: provider
            )

        case .notAuthenticated:
            statusBlock(
                icon: "person.crop.circle.badge.exclamationmark",
                title: "\(provider.displayName) is not authenticated",
                message: "Run `\(provider.commandName)` in a terminal and sign in, then refresh.",
                recovery: [.openTerminal, .refresh],
                provider: provider
            )

        case .keychainAccessDenied:
            statusBlock(
                icon: "lock.trianglebadge.exclamationmark",
                title: "Keychain access denied",
                message: "Tokenmax needs to read the \(provider.displayName) credentials item to fetch usage. Click Refresh and choose Always Allow.",
                // No Open Terminal: a terminal cannot grant a keychain prompt.
                recovery: [.refresh],
                provider: provider
            )

        case let .tokenExpired(lastGood):
            VStack(alignment: .leading, spacing: 10) {
                statusBlock(
                    icon: "arrow.clockwise.circle",
                    title: "Tokenmax needs Claude Code to renew its saved credential",
                    message: "Your active Claude Code session may still work. Tokenmax's saved credential was rejected; it updates when Claude Code renews its login. Keep working, then refresh. If it does not recover, open Terminal and run `claude login`.",
                    recovery: [.refresh, .openTerminalForLogin],
                    provider: provider
                )
                if let lastGood {
                    windows(for: lastGood, provider: provider, forceStale: true)
                }
            }

        case .needsReauthentication:
            statusBlock(
                icon: "key.slash",
                title: "\(provider.displayName) needs re-authentication",
                message: "Run `\(provider.commandName)` and sign in again.",
                // Refreshing cannot help until the user has signed in again.
                recovery: [.openTerminal],
                provider: provider
            )

        case let .unavailable(lastGood, message):
            VStack(alignment: .leading, spacing: 10) {
                statusBlock(
                    icon: "exclamationmark.triangle",
                    title: "Usage unavailable",
                    message: message,
                    recovery: [.retry],
                    provider: provider
                )
                if let lastGood {
                    windows(for: lastGood, provider: provider, forceStale: true)
                }
            }

        case let .loaded(snapshot):
            if snapshot.windows.isEmpty {
                statusBlock(
                    icon: "chart.bar",
                    title: "No quota windows returned",
                    message: "\(provider.displayName) did not report any usage windows for this account.",
                    recovery: [.retry],
                    provider: provider
                )
            } else {
                windows(for: snapshot, provider: provider, forceStale: usage.isStale(for: provider))
            }
        }
    }

    private func windows(
        for snapshot: UsageSnapshot,
        provider: TokenmaxProvider,
        forceStale: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let session = snapshot.sessionWindow {
                VStack(alignment: .leading, spacing: 5) {
                    UsageWindowView(
                        window: session,
                        isStale: forceStale,
                        now: usage.tick,
                        projection: projection(for: session, forceStale: forceStale)
                    )
                    reminderLine(for: .session, provider: provider)
                    if provider == .claudeCode { openerLine }
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
                    reminderLine(for: .weekly, provider: provider)
                }
            }
            if provider == .codex,
               let resetText = UsageWindowPresentation.availableResetText(for: snapshot, now: usage.tick) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise.circle")
                        .font(.system(size: 10))
                    Text(resetText)
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
                .help("A banked reset refreshes Codex's eligible usage windows. Redeem it from Codex after reviewing its offer details.")
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
    private func reminderLine(for kind: UsageWindowKind, provider: TokenmaxProvider) -> some View {
        // "No session running" is read off the pre-opener snapshot, so during
        // verification it contradicts the opener line right below it. The
        // opener line is the one telling the truth; this one steps aside.
        if provider == .claudeCode, kind == .session, case .verifying = opener.activity {
            EmptyView()
        } else if let status = notifications.status(for: provider, kind: kind) {
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
        switch opener.activity {
        case .sending:
            return "Opening the next session…"
        case let .verifying(sentAt):
            // Naming the time and the wait is the whole point: the numbers
            // above are visibly unchanged, and without this the run reads as a
            // failure for the three minutes it takes the endpoint to catch up.
            let time = sentAt.formatted(date: .omitted, time: .shortened)
            return "Session opened at \(time) — numbers catch up within 3 min"
        case .idle:
            break
        }

        switch opener.decision.skipReason {
        case .none:
            return "Opener ready"
        case .windowAlreadyActive, .disabled, .noExpiredWindow:
            return nil
        case let .some(reason):
            return "Opener: \(reason.explanation)"
        }
    }

    /// A failure state, with the actions that can actually resolve it.
    ///
    /// Only offered where they help: an "Open Terminal" button next to a stale
    /// reading would do nothing about staleness, and a button that cannot work
    /// teaches the user to ignore the ones that can.
    private func statusBlock(
        icon: String,
        title: String,
        message: String?,
        recovery: [Recovery] = [],
        provider: TokenmaxProvider = .claudeCode
    ) -> some View {
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
                if !recovery.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(recovery) { action in
                            Button(action.title) { perform(action, provider: provider) }
                        }
                    }
                    .font(.system(size: 11))
                    .padding(.top, 2)
                }
                // No age line here: the provider's own header sits directly
                // above this block and already carries it. Repeating it read as
                // two different timestamps for the same reading.
            }
        }
    }

    enum Recovery: String, Identifiable {
        case refresh
        case retry
        case openTerminal
        case openTerminalForLogin

        var id: String { rawValue }

        var title: String {
            switch self {
            case .refresh: "Refresh"
            case .retry: "Retry"
            case .openTerminal: "Open Terminal"
            case .openTerminalForLogin: "Open Terminal + Copy Login"
            }
        }
    }

    private func perform(_ action: Recovery, provider: TokenmaxProvider = .claudeCode) {
        switch action {
        case .refresh, .retry:
            Task {
                await usage.refresh(
                    reason: "recovery",
                    manual: true,
                    retryDeniedKeychainAccess: true,
                    provider: provider
                )
            }
        case .openTerminal:
            // All the auth and install failures are fixed by running `claude`
            // somewhere, and somewhere is home.
            ManualRunService.openTerminalForRecovery(
                application: settingsStore.settings.terminalApplication
            )
        case .openTerminalForLogin:
            ManualRunService.openTerminalForRecovery(
                application: settingsStore.settings.terminalApplication,
                commandToPaste: "claude login"
            )
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
                Button("Open Queue") { open(TokenmaxWindow.queue) }
            }
            // The footer button sits below every provider section, so it
            // refreshes every provider. The per-provider Refresh links in the
            // section headers are the narrow ones.
            Button {
                Task {
                    await usage.refreshAll(
                        reason: "manual",
                        manual: true,
                        retryDeniedKeychainAccess: true
                    )
                }
            } label: {
                if usage.isRefreshingAny {
                    Text("Refreshing…")
                } else {
                    Text("Refresh")
                }
            }
            .disabled(usage.isRefreshingAny)

            Spacer()

            // Settings used to sit behind an ellipsis menu next to Quit. It is
            // the one thing here anybody opens more than once, so it gets the
            // button; Quit, which is used once and never in a hurry, moved to
            // the menubar icon's right-click menu.
            SettingsLink {
                Text("Settings…")
            }
        }
    }

    /// Activation first, then the named queue window. `openWindow` only orders
    /// it to the front *within* this app; putting the app itself in front of
    /// every other one is a separate step. Settings uses the native
    /// `SettingsLink`, which performs both parts itself.
    private func open(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }
}
