import SwiftUI

/// The two quota windows, compressed to one line each.
///
/// The popover's `UsageWindowView` is the detailed reading; this is the version
/// that has to sit above a task list without pushing it off screen. Same rules,
/// same words — both go through `UsageWindowPresentation` — but a bar three
/// points tall and no pace projection.
///
/// Every failure mode the provider can report gets its own line rather than a
/// blank space, because "we could not read your quota" and "you have none left"
/// must never look the same.
struct QueueQuotaSummaryView: View {
    let state: UsageState
    let isStale: Bool
    let now: Date

    /// Which provider these numbers belong to. Every status string below is
    /// built from it — they used to say "Claude Code" even when rendering
    /// Codex's failures.
    var provider: TokenmaxProvider = .claudeCode

    /// Narrows the fixed column widths so two of these fit side by side in the
    /// queue window. Same rows, same words — just less room reserved.
    var isCompact = false

    /// Shown when the state carries a recovery action worth offering.
    var onRefresh: (() -> Void)?
    var onOpenTerminal: (() -> Void)?

    private var name: String { provider.displayName }
    private var command: String { provider.commandName }

    private var labelWidth: CGFloat { isCompact ? 44 : 48 }
    private var barWidth: CGFloat { isCompact ? 72 : 120 }
    private var remainingWidth: CGFloat { isCompact ? 62 : 78 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            switch state {
            case .loading:
                message("Reading \(name) usage…", icon: "arrow.triangle.2.circlepath")

            case .claudeCodeNotInstalled:
                problem(
                    "\(name) is not installed",
                    detail: "Tokenmax could not find the \(command) CLI.",
                    actions: [.openTerminal, .refresh]
                )

            case .notAuthenticated:
                problem(
                    "\(name) is not signed in",
                    detail: "Run \(command) in a terminal and sign in.",
                    actions: [.openTerminal, .refresh]
                )

            case .keychainAccessDenied:
                problem(
                    "Keychain access denied",
                    detail: "Refresh and choose Always Allow so Tokenmax can read the \(name) credentials.",
                    actions: [.refresh]
                )

            case .needsReauthentication:
                problem(
                    "\(name) needs signing in again",
                    detail: "The stored credentials cannot be refreshed.",
                    actions: [.openTerminal]
                )

            case let .tokenExpired(lastGood):
                // Self-healing: Claude Code rotates the token the next time it
                // runs, so this is a note rather than something to act on.
                degraded(
                    lastGood,
                    note: "Waiting for \(name) to refresh its token.",
                    actions: []
                )

            case let .unavailable(lastGood, message):
                degraded(lastGood, note: message, actions: [.refresh])

            case let .loaded(snapshot):
                if snapshot.windows.isEmpty {
                    problem(
                        "No quota windows reported",
                        detail: "\(name) did not return any usage windows for this account.",
                        actions: [.refresh]
                    )
                } else {
                    windows(snapshot, isStale: isStale)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Windows

    @ViewBuilder
    private func windows(_ snapshot: UsageSnapshot, isStale: Bool) -> some View {
        // A missing window is stated rather than left out. An account with no
        // weekly limit and an account whose weekly reading failed are different
        // situations, and a silently absent row conflates them.
        if let session = snapshot.sessionWindow {
            row(session, isStale: isStale)
        } else {
            missingRow("Session")
        }

        if let weekly = snapshot.weeklyWindow {
            row(weekly, isStale: isStale)
        } else {
            missingRow("Weekly")
        }

        if isStale {
            staleNote
        }
    }

    private func row(_ window: UsageWindow, isStale: Bool) -> some View {
        HStack(spacing: 8) {
            Text(window.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)

            bar(window, isStale: isStale)
                .frame(width: barWidth)

            Text(UsageWindowPresentation.remainingText(for: window))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isStale ? .secondary : .primary)
                .frame(width: remainingWidth, alignment: .leading)

            Text(UsageWindowPresentation.compactResetText(for: window, isStale: isStale, now: now))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(window, isStale: isStale))
    }

    /// One string per row, because four separate labels read as four unrelated
    /// fragments to VoiceOver.
    private func accessibilityLabel(_ window: UsageWindow, isStale: Bool) -> String {
        var parts = [window.label, UsageWindowPresentation.remainingText(for: window)]
        if isStale {
            parts.append("reading is out of date, countdown unavailable")
        } else {
            parts.append(UsageWindowPresentation.resetText(for: window, isStale: false, now: now))
        }
        return parts.joined(separator: ", ")
    }

    private func bar(_ window: UsageWindow, isStale: Bool) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.22))

                if let fraction = UsageWindowPresentation.fillFraction(for: window, isStale: isStale) {
                    Capsule()
                        .fill(barColor(window))
                        .frame(width: max(3, geometry.size.width * fraction))
                }
            }
        }
        .frame(height: 5)
    }

    private func barColor(_ window: UsageWindow) -> Color {
        switch window.remainingPercent ?? 100 {
        case ..<10: .red
        case ..<25: .orange
        default: .green
        }
    }

    private func missingRow(_ label: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            Text("Not reported for this account")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Degraded and failed states

    /// Carries the last good reading through a failure, clearly marked. The
    /// numbers are still the best information available; presenting them as
    /// current is what would be wrong, not showing them at all.
    @ViewBuilder
    private func degraded(_ lastGood: UsageSnapshot?, note: String, actions: [RecoveryAction]) -> some View {
        if let lastGood, !lastGood.windows.isEmpty {
            windows(lastGood, isStale: true)
            noteLine(note, actions: actions)
        } else {
            problem("Usage unavailable", detail: note, actions: actions)
        }
    }

    private var staleNote: some View {
        noteLine("This reading is out of date.", actions: [.refresh])
    }

    private func noteLine(_ text: String, actions: [RecoveryAction]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
            actionButtons(actions)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
    }

    private func message(_ text: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11))
            Text(text).font(.system(size: 11))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
    }

    private func problem(_ title: String, detail: String, actions: [RecoveryAction]) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .medium))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !actions.isEmpty {
                    HStack(spacing: 6) { actionButtons(actions) }
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Recovery actions

    /// Only offered where they can actually help — an "Open Terminal" button on
    /// a stale reading would do nothing for the problem it is next to.
    enum RecoveryAction {
        case refresh
        case openTerminal
    }

    @ViewBuilder
    private func actionButtons(_ actions: [RecoveryAction]) -> some View {
        ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
            switch action {
            case .refresh:
                if let onRefresh {
                    Button("Refresh", action: onRefresh)
                        .font(.system(size: 10))
                        .buttonStyle(.link)
                }
            case .openTerminal:
                if let onOpenTerminal {
                    Button("Open Terminal", action: onOpenTerminal)
                        .font(.system(size: 10))
                        .buttonStyle(.link)
                }
            }
        }
    }
}
