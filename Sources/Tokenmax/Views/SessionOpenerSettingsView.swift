import SwiftUI

struct SessionOpenerSettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var modelCatalog: ModelCatalogStore
    @EnvironmentObject private var usage: UsageRefreshCoordinator
    @EnvironmentObject private var opener: SessionOpenerCoordinator

    @State private var confirmingSend = false

    private var openerSettings: Binding<SessionOpenerSettings> {
        $settingsStore.settings.sessionOpener
    }

    private var isEnabled: Bool { settingsStore.settings.sessionOpener.enabled }

    var body: some View {
        Form {
            Section {
                Toggle("Open the next session automatically", isOn: openerSettings.enabled)
                Text("When the five-hour window ends, send one tiny Claude Code request so a fresh window starts. This spends a small amount of quota on purpose, which is why it is off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker("Delay after reset", selection: openerSettings.delaySeconds) {
                    ForEach(SessionOpenerSettings.delayOptions, id: \.self) { seconds in
                        Text(delayLabel(seconds)).tag(seconds)
                    }
                }
                // Only the cheap families: the opener exists to consume one
                // token, and an expensive model here is money for nothing.
                Picker("Model", selection: openerSettings.model) {
                    ForEach(modelCatalog.aliases.filter(SessionOpenerSettings.modelOptions.contains), id: \.self) { model in
                        Text(SessionOpenerSettings.modelDisplayName(model)).tag(model)
                    }
                }
                Picker("Thinking", selection: Binding(
                    get: { openerSettings.effort.wrappedValue ?? "" },
                    set: { openerSettings.effort.wrappedValue = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Default").tag("")
                    ForEach(modelCatalog.effortLevels(for: openerSettings.model.wrappedValue), id: \.self) { level in
                        Text(TaskExecutionPolicy.effortDisplayName(level)).tag(level)
                    }
                }
                Text("Haiku on the lowest thinking grade is the cheapest combination, so it opens the window for the least quota. The opener does no work — it exists only to consume a token.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!isEnabled)

            Section("Safety") {
                Picker("Minimum weekly quota remaining", selection: openerSettings.minimumWeeklyRemainingPercent) {
                    ForEach(SessionOpenerSettings.weeklyThresholdOptions, id: \.self) { value in
                        Text("\(Int(value))%").tag(value)
                    }
                }
                Toggle("Respect quiet hours", isOn: openerSettings.respectQuietHours)
                Toggle("Skip when usage credits may be charged", isOn: openerSettings.skipWhenExtraUsageEnabled)
                Toggle("Verify the new window afterwards", isOn: openerSettings.verifyAfterRun)

                LabeledContent("Extra paid usage") {
                    Text(extraUsageDescription)
                        .font(.caption)
                        .foregroundStyle(extraUsageBlocks ? .orange : .secondary)
                }

                // Without this the guard is invisible: the account is fine, the
                // settings look right, and the opener simply never runs. Say so
                // where the toggle that resolves it is.
                if extraUsageBlocks {
                    Text(extraUsageBlockedExplanation)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Not settings. Offering a switch for either would only offer a
                // way to turn the safety off.
                Text("Always enforced: the request runs with every tool disabled, and never runs under an API key — only a Claude subscription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!isEnabled)

            Section("Status") {
                HStack(spacing: 5) {
                    Image(systemName: statusIcon)
                        .font(.caption)
                    Text(statusText)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .foregroundStyle(statusIsNoteworthy ? Color.orange : Color.secondary)

                if let attempt = opener.lastAttempt {
                    LabeledContent("Last attempt") {
                        Text(attemptSummary(attempt))
                            .font(.caption)
                            .multilineTextAlignment(.trailing)
                    }
                }

                HStack {
                    Button("Check eligibility") {
                        _ = opener.checkEligibility()
                    }
                    Button("Send opener now") {
                        confirmingSend = true
                    }
                    .disabled(opener.isRunning)
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Send an opener now?",
            isPresented: $confirmingSend,
            titleVisibility: .visible
        ) {
            Button("Send and spend quota") {
                Task { await opener.sendNow() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This sends a real Claude Code request using \(SessionOpenerSettings.modelDisplayName(settingsStore.settings.sessionOpener.model)) and consumes a small amount of your session and weekly quota. The safety conditions still apply — if any of them fails, nothing is sent.")
        }
        .onAppear { _ = opener.checkEligibility() }
    }

    private func delayLabel(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) seconds" : "\(seconds / 60) minute\(seconds == 60 ? "" : "s")"
    }

    /// "Not reported" is deliberately distinct from "disabled": the opener
    /// refuses to run on an unknown, and the user needs to see why rather than
    /// watch it silently never fire.
    private var extraUsageDescription: String {
        switch usage.state.snapshot?.extraUsageEnabled {
        case true: "Enabled on this account"
        case false: "Disabled"
        case nil: "Not reported by Anthropic"
        }
    }

    /// True when this account's extra-usage state, combined with the toggle,
    /// means the opener can never fire.
    private var extraUsageBlocks: Bool {
        guard settingsStore.settings.sessionOpener.skipWhenExtraUsageEnabled else { return false }
        return usage.state.snapshot?.extraUsageEnabled != false
    }

    private var extraUsageBlockedExplanation: String {
        if usage.state.snapshot?.extraUsageEnabled == true {
            return "“Skip when usage credits may be charged” is on, so the opener will not run while this account has credits enabled. It is off by default because the opener only ever runs into a window that has just reset, with the weekly quota above your threshold — a charge cannot be reached from there. Switch it off to rely on that threshold, or leave it on for a guard that holds even if the reported percentages are wrong."
        }
        return "The opener will not run until this is known, because an unreported setting is treated as unsafe. Switch off “Skip when usage credits may be charged” to proceed on the weekly quota threshold alone."
    }

    private var statusIsNoteworthy: Bool {
        opener.decision.skipReason?.isNoteworthy ?? false
    }

    private var statusIcon: String {
        if opener.isRunning { return "arrow.triangle.2.circlepath" }
        return opener.decision.skipReason == nil ? "bolt.circle" : "pause.circle"
    }

    private var statusText: String {
        switch opener.activity {
        case .sending:
            return "Sending the opener…"
        case .verifying:
            // The send is already done and paid for. Saying "sending" here for
            // another three minutes invites a second click on a button that
            // would spend again.
            return "Sent. Confirming the new window — this takes up to 3 minutes."
        case .idle:
            break
        }
        // The OAuth reader can retain a last good quota snapshot while Claude
        // Code's token is waiting to be renewed. Do not make that look like a
        // scheduling problem: an opener cannot safely act on an old weekly
        // number, and the user needs the concrete recovery step.
        if usage.isAwaitingTokenRenewal {
            return "Claude Code’s access token expired. Open Claude Code or run ‘claude login’, then refresh."
        }
        guard let reason = opener.decision.skipReason else {
            return "Ready to open the next window."
        }
        return reason.explanation
    }

    private func attemptSummary(_ attempt: SessionOpenerAttempt) -> String {
        let time = attempt.startedAt.formatted(date: .abbreviated, time: .shortened)
        let model = SessionOpenerSettings.modelDisplayName(attempt.model)

        switch attempt.outcome {
        case .verified:
            if let resetAt = attempt.verifiedResetAt {
                return "\(time) · \(model) · new window until \(resetAt.formatted(date: .omitted, time: .shortened))"
            }
            return "\(time) · \(model) · succeeded"
        case .sent:
            return "\(time) · \(model) · sent, verifying"
        case .unverified:
            return "\(time) · \(model) · sent, but no new window was confirmed"
        case .failed:
            return "\(time) · \(model) · failed — \(attempt.errorMessage ?? "unknown error")"
        }
    }
}
