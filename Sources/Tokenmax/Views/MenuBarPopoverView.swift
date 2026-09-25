import SwiftUI

struct MenuBarPopoverView: View {
    @EnvironmentObject private var usage: ProviderUsageCoordinator
    /// This view counts down, so it observes the clock as well as the reading.
    @EnvironmentObject private var clock: CountdownClock
    @EnvironmentObject private var taskStore: TaskStore
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var notifications: NotificationCoordinator
    @EnvironmentObject private var opener: SessionOpenerCoordinator
    @EnvironmentObject private var autoRun: QueueAutoRunCoordinator
    @EnvironmentObject private var updates: UpdateCheckCoordinator
    @EnvironmentObject private var signIn: ClaudeSignInCoordinator
    @EnvironmentObject private var renewal: ClaudeTokenRenewalCoordinator

    @Environment(\.openWindow) private var openWindow

    /// Every enabled provider, whichever icon was clicked: the icon is the
    /// glance, the popover the whole picture, and a popover that changed with
    /// the icon under the pointer made comparing two providers a matter of
    /// clicking back and forth. In the icons' order, so the sections read left
    /// to right like the menu bar — and a hidden icon's provider is still here,
    /// since hiding an icon never stops watching it.
    ///
    /// Still filtered through the enabled list: a provider switched off while
    /// the popover is open must not render a section for a coordinator that
    /// has stopped.
    private var shownProviders: [TokenmaxProvider] {
        settingsStore.settings.orderedMenuBarProviders
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            appHeader
            if let opportunity = usage.burnOpportunity {
                burnBanner(opportunity)
            }
            // A switched-off provider loses its section *and* the divider above
            // it — leaving the rule behind would read as an empty section.
            ForEach(shownProviders) { provider in
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
                Text("\(Int(opportunity.remainingPercent.rounded()))% left, resetting in \(RelativeTime.countdown(opportunity.timeUntilReset(now: clock.now)))")
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

        case .claudeCodeNotInstalled where provider == .cursor:
            statusBlock(
                icon: "questionmark.folder",
                title: "Cursor is not installed",
                message: "Tokenmax reads Cursor's usage through the Cursor app's own sign-in, and could not find the app's data on this Mac. Install Cursor and sign in, then refresh.",
                recovery: [.refresh],
                provider: provider
            )

        case .claudeCodeNotInstalled:
            statusBlock(
                icon: "questionmark.folder",
                title: "\(provider.displayName) is not installed",
                message: "Tokenmax could not find the \(provider.commandName) CLI on this Mac.",
                recovery: [.openTerminal, .refresh],
                provider: provider
            )

        // Cursor renews its own sign-in whenever it runs, and Tokenmax never
        // touches it — so the fix is opening Cursor, not a terminal.
        case .notAuthenticated where provider == .cursor:
            statusBlock(
                icon: "person.crop.circle.badge.exclamationmark",
                title: "Cursor is not signed in",
                message: "Open Cursor and sign in, then refresh. If you are signed in, Cursor's saved sign-in was rejected; opening Cursor renews it.",
                recovery: [.refresh],
                provider: provider
            )

        case .notAuthenticated:
            statusBlock(
                icon: "person.crop.circle.badge.exclamationmark",
                title: "\(provider.displayName) is not authenticated",
                message: provider == .claudeCode
                    ? "Sign in with your Claude account. Tokenmax runs Claude Code's own login, which opens in your browser."
                    : "Run `\(provider.commandName)` in a terminal and sign in, then refresh.",
                recovery: provider == .claudeCode ? [.signIn, .refresh] : [.openTerminal, .refresh],
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
                    message: "Your active Claude Code session may still work. Tokenmax's saved credential was rejected, so it asks Claude Code to renew its login in the background — no prompt is sent and no usage is spent. Refresh asks again straight away. If it does not recover, sign in again — Claude's login page opens in your browser.",
                    recovery: [.refresh, .signIn],
                    provider: provider
                )
                renewalLine
                if let lastGood {
                    windows(for: lastGood, provider: provider, forceStale: true)
                }
            }

        case .needsReauthentication:
            statusBlock(
                icon: "key.slash",
                title: "\(provider.displayName) needs re-authentication",
                message: provider == .claudeCode
                    ? "Sign in with your Claude account again. Claude's login page opens in your browser."
                    : "Run `\(provider.commandName)` and sign in again.",
                // Refreshing cannot help until the user has signed in again.
                recovery: provider == .claudeCode ? [.signIn] : [.openTerminal],
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
                        now: clock.now,
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
                        now: clock.now,
                        projection: projection(for: weekly, forceStale: forceStale)
                    )
                    reminderLine(for: .weekly, provider: provider)
                }
            }
            // Cursor's meters. No reminder line: reminders are set per
            // session and weekly window, and a billing cycle is neither.
            ForEach(snapshot.windows.filter { $0.kind == .billingCycle }) { window in
                UsageWindowView(
                    window: window,
                    isStale: forceStale,
                    now: clock.now,
                    projection: projection(for: window, forceStale: forceStale)
                )
            }
            // One line per title, so the text is its own identity.
            ForEach(UsageWindowPresentation.availableResetLines(for: snapshot, now: clock.now), id: \.self) { resetText in
                accountLine(
                    icon: "arrow.counterclockwise.circle",
                    text: resetText,
                    help: UsageWindowPresentation.resetHelpText(for: provider)
                )
            }
            if let creditText = UsageWindowPresentation.oneTimeCreditText(for: snapshot, now: clock.now) {
                accountLine(icon: "cloud", text: creditText, help: UsageWindowPresentation.oneTimeCreditHelpText)
            }
        }
    }

    /// A fact about the account rather than either window, so it sits below
    /// both meters.
    private func accountLine(icon: String, text: String, help: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 10))
        }
        .foregroundStyle(.secondary)
        .help(help)
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
                Text(status.summary(now: clock.now))
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
                                .disabled(action == .signIn && signIn.isBusy)
                        }
                    }
                    .font(.system(size: 11))
                    .padding(.top, 2)
                }
                if recovery.contains(.signIn) {
                    signInLine
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
        case signIn

        var id: String { rawValue }

        var title: String {
            switch self {
            case .refresh: "Refresh"
            case .retry: "Retry"
            case .openTerminal: "Open Terminal"
            case .signIn: "Sign In with Claude"
            }
        }
    }

    private func perform(_ action: Recovery, provider: TokenmaxProvider = .claudeCode) {
        switch action {
        case .refresh, .retry:
            // The one Refresh that can do more than re-read: while the saved
            // credential is rejected, the click is also the user asking for a
            // renewal now rather than after the cooldown.
            if provider == .claudeCode, case .tokenExpired = usage.state(for: .claudeCode) {
                renewal.userRequested()
            }
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
        case .signIn:
            signIn.start()
        }
    }

    /// The sign-in happens in the browser, out of sight of this popover, so the
    /// wait has to be said out loud — otherwise the unchanged error above reads
    /// as a button that did nothing.
    @ViewBuilder
    private var signInLine: some View {
        switch signIn.activity {
        case .waitingForBrowser:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Finish signing in in your browser…")
                Button("Cancel") { signIn.cancel() }
                    .buttonStyle(.link)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        case let .waitingForReading(at):
            // The request floor, not a slow network: see `ClaudeSignIn.refreshDelay`.
            Text("Signed in. Checking usage at \(at.formatted(date: .omitted, time: .standard)).")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        case .idle:
            if let message = signIn.lastOutcome?.message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What the background renewal is doing, said out loud for the same reason
    /// as the sign-in line: it happens out of sight, and an unchanged error
    /// above reads as nothing happening.
    @ViewBuilder
    private var renewalLine: some View {
        switch renewal.activity {
        case .renewing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Asking Claude Code to renew its login…")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.leading, 25)
        case let .waitingForReading(at):
            Text("Claude Code renewed its login. Checking usage at \(at.formatted(date: .omitted, time: .standard)).")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.leading, 25)
        case .idle:
            if let reason = renewal.lastSuppression {
                Text(reason.explanation)
                    .font(.system(size: 10))
                    .foregroundStyle(reason == .noEffect ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 25)
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
                        Text("Starting a task in \(pending.secondsRemaining(now: clock.now))s")
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
            Button("Settings…") {
                NotificationCenter.default.post(name: .tokenmaxOpenSettings, object: nil)
            }
        }
    }

    /// Activation first, then the named queue window. `openWindow` only orders
    /// it to the front *within* this app; putting the app itself in front of
    /// every other one is a separate step. Settings is routed through the app
    /// delegate because its native scene needs the same treatment even when
    /// this optional status-item view does not exist.
    private func open(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }
}
