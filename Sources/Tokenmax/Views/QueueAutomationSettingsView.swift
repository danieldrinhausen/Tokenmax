import SwiftUI

struct QueueAutomationSettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var modelCatalog: ModelCatalogStore
    @EnvironmentObject private var codexModelCatalog: CodexModelCatalogStore
    @EnvironmentObject private var usage: ProviderUsageCoordinator
    @EnvironmentObject private var taskStore: TaskStore
    @EnvironmentObject private var autoRun: QueueAutoRunCoordinator

    @State private var confirmingRun = false
    @State private var manualError: String?

    private var auto: Binding<QueueAutoRunSettings> {
        $settingsStore.settings.queueAutoRun
    }

    private var isEnabled: Bool { settingsStore.settings.queueAutoRun.enabled }

    var body: some View {
        Form {
            Section {
                Toggle("Automatically run eligible tasks", isOn: auto.enabled)
                Text("When a quota window is close to resetting, Tokenmax can spend what would otherwise expire by running a queued task you have approved. This runs a real agent against a real project and can change files, which is why it is off by default and starts in preview mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !settingsStore.settings.queueEnabled {
                    Label("The task queue is switched off in General, so nothing can run.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Mode") {
                Picker("Mode", selection: auto.mode) {
                    ForEach(QueueAutoRunMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                Text(settingsStore.settings.queueAutoRun.mode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!isEnabled)

            Section("Timing") {
                Picker("Start tasks when the session resets in", selection: auto.leadTimeMinutes) {
                    ForEach(QueueAutoRunSettings.leadTimeOptions, id: \.self) { minutes in
                        Text("\(minutes) minutes").tag(minutes)
                    }
                }
                Picker("Safety margin before reset", selection: auto.safetyMarginMinutes) {
                    ForEach(QueueAutoRunSettings.safetyMarginOptions, id: \.self) { minutes in
                        Text("\(minutes) minutes").tag(minutes)
                    }
                }
                Picker("Automatic start delay", selection: auto.startDelaySeconds) {
                    ForEach(QueueAutoRunSettings.startDelayOptions, id: \.self) { seconds in
                        Text("\(seconds) seconds").tag(seconds)
                    }
                }
                Text("A task only starts if its runtime limit fits before the safety margin. The start delay is your chance to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Run a missed appointment up to", selection: auto.scheduleGraceMinutes) {
                    ForEach(QueueAutoRunSettings.scheduleGraceOptions, id: \.self) { minutes in
                        Text("\(minutes) minutes late").tag(minutes)
                    }
                }
                Text("A task given a specific time is skipped if that time passed while the Mac was asleep. Beyond this window it stops waiting and asks for a new time, rather than starting hours late against a project that has moved on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("When the reset arrives mid-task", selection: auto.resetBoundaryBehavior) {
                    ForEach(ResetBoundaryBehavior.allCases) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
                Text("Stopping a task halfway through an edit usually leaves the project worse than not having run it, so finishing is the default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!isEnabled)

            Section("Limits") {
                Picker("Minimum session quota", selection: auto.minimumSessionRemainingPercent) {
                    ForEach(QueueAutoRunSettings.sessionThresholdOptions, id: \.self) { value in
                        Text("\(Int(value))%").tag(value)
                    }
                }
                Picker("Minimum weekly quota", selection: auto.minimumWeeklyRemainingPercent) {
                    ForEach(QueueAutoRunSettings.weeklyThresholdOptions, id: \.self) { value in
                        Text("\(Int(value))%").tag(value)
                    }
                }
                Picker("Maximum tasks per session", selection: auto.maximumTasksPerWindow) {
                    ForEach(QueueAutoRunSettings.maximumTasksOptions, id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
                Picker("Maximum total runtime", selection: auto.maximumRuntimeMinutes) {
                    ForEach(QueueAutoRunSettings.maximumRuntimeOptions, id: \.self) { value in
                        Text("\(value) minutes").tag(value)
                    }
                }
            }
            .disabled(!isEnabled)

            codexSection

            // Not gated on `isEnabled`: these seed the task editor, which is
            // useful whether or not automatic execution is switched on.
            Section("New task defaults") {
                if settingsStore.settings.enabledProviders.count > 1 {
                    Picker("Provider", selection: $settingsStore.settings.defaultTaskProvider) {
                        ForEach(TokenmaxProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                }

                claudeTaskDefaults
                codexTaskDefaults

                Text("What a new task starts with. Every one is overridable per task, and changing them here leaves existing tasks alone. A new task is set up for both providers at once, so switching its provider in the editor lands on the settings you chose here rather than on bare defaults.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Safety") {
                Toggle("Only run tasks explicitly marked for automation", isOn: auto.onlyRunApprovedTasks)
                Toggle("Pause the queue after the first failure", isOn: auto.pauseAfterFailure)
                Toggle("Require fresh quota data", isOn: auto.requireFreshUsageData)
                Toggle("Respect quiet hours", isOn: auto.respectQuietHours)
                Toggle("Never run when usage credits could be charged", isOn: auto.skipWhenExtraUsageEnabled)

                Text(extraUsageDescription)
                    .font(.caption)
                    .foregroundStyle(extraUsageBlocks ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Always enforced: one task at a time, never with unrestricted permissions, and never under an API key — only a Claude or ChatGPT subscription. Each task's own permissions and limits are set when you edit it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!isEnabled)

            Section("Notifications") {
                Toggle("Notify when a task starts", isOn: auto.notifyOnStart)
                Toggle("Notify when a task completes", isOn: auto.notifyOnCompletion)
                Text("Failures always notify — a queue that has silently stopped looks the same as an app that is broken.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!isEnabled)

            statusSection
        }
        .formStyle(.grouped)
        .onAppear {
            modelCatalog.refreshIfStale()
            codexModelCatalog.refreshIfStale()
        }
        .confirmationDialog(
            "Run the next eligible task now?",
            isPresented: $confirmingRun,
            titleVisibility: .visible
        ) {
            Button("Run and spend quota") {
                if let reason = autoRun.runNextEligibleNow() {
                    manualError = reason.explanation
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This starts a real run against the task's working directory, with the task's own provider, model, permissions, and limits. It ignores the schedule and quota thresholds so you can test outside a burn window — the directory, account, and per-task limits still apply.")
        }
        .alert("Could not run", isPresented: .init(
            get: { manualError != nil },
            set: { if !$0 { manualError = nil } }
        )) {
            Button("OK") { manualError = nil }
        } message: {
            Text(manualError ?? "")
        }
        .onAppear { autoRun.checkEligibility() }
    }

    // MARK: - New task defaults

    /// Shown only for a provider that is switched on. A section offering
    /// defaults for an agent the user is not monitoring is noise.
    @ViewBuilder
    private var claudeTaskDefaults: some View {
        if settingsStore.settings.claudeCodeEnabled {
            Picker("Claude model", selection: $settingsStore.settings.defaultTaskModel) {
                ForEach(modelCatalog.aliases, id: \.self) { alias in
                    Text(TaskExecutionPolicy.modelDisplayName(alias)).tag(alias)
                }
                if !modelCatalog.models.isEmpty {
                    Divider()
                    ForEach(modelCatalog.models) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
            }
            Picker("Claude thinking", selection: Binding(
                get: { settingsStore.settings.defaultTaskEffort ?? "" },
                set: { settingsStore.settings.defaultTaskEffort = $0.isEmpty ? nil : $0 }
            )) {
                Text("Default").tag("")
                ForEach(modelCatalog.effortLevels(for: settingsStore.settings.defaultTaskModel), id: \.self) {
                    Text(TaskExecutionPolicy.effortDisplayName($0)).tag($0)
                }
            }
            Picker("Claude spend limit", selection: $settingsStore.settings.defaultTaskBudgetUSD) {
                ForEach(TaskExecutionPolicy.budgetOptions, id: \.self) { value in
                    Text(value == value.rounded()
                        ? String(format: "$%.0f", value)
                        : String(format: "$%.2f", value)
                    ).tag(value)
                }
            }
            Text("An alias like Opus always resolves to the newest model of that family; the list itself is fetched from Anthropic, so a new model appears without updating Tokenmax.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Codex has no spend limit here because it reports no per-run cost, so
    /// there is nothing Tokenmax could enforce. Its sandbox is the equivalent
    /// decision, and it is the one that matters most.
    @ViewBuilder
    private var codexTaskDefaults: some View {
        if settingsStore.settings.codexEnabled {
            Picker("Codex model", selection: Binding(
                get: { settingsStore.settings.defaultCodexModel ?? "" },
                set: { settingsStore.settings.defaultCodexModel = $0.isEmpty ? nil : $0 }
            )) {
                Text(codexModelCatalog.defaultModelName.map { "Codex default (\($0))" } ?? "Codex default")
                    .tag("")
                if !codexModelCatalog.models.isEmpty {
                    Divider()
                    ForEach(codexModelCatalog.models) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
            }
            Picker("Codex reasoning", selection: Binding(
                get: { settingsStore.settings.defaultCodexReasoningEffort ?? "" },
                set: { settingsStore.settings.defaultCodexReasoningEffort = $0.isEmpty ? nil : $0 }
            )) {
                Text("Config default").tag("")
                ForEach(codexModelCatalog.reasoningEfforts(for: settingsStore.settings.defaultCodexModel), id: \.self) {
                    Text($0.capitalized).tag($0)
                }
            }
            Picker("Codex sandbox", selection: $settingsStore.settings.defaultCodexSandbox) {
                ForEach(CodexSandbox.allCases) { sandbox in
                    Text(sandbox.displayName).tag(sandbox)
                }
            }
            Text("Leaving the model and reasoning on their defaults defers to your own ~/.codex/config.toml, so changing Codex there changes new tasks here. Codex reports no per-run cost, so there is no spending limit to set — the sandbox is what bounds a run.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Codex

    /// Codex automation, kept behind its own switch and its own three figures.
    ///
    /// Separate from the master switch on purpose: someone who trusted Claude to
    /// run unattended has not thereby agreed to a second agent doing the same,
    /// and an upgrade must never add one for them.
    @ViewBuilder
    private var codexSection: some View {
        Section("Codex") {
            Toggle("Also run Codex tasks automatically", isOn: $settingsStore.settings.codexAutoRunEnabled)

            if !settingsStore.settings.codexEnabled {
                Label("Codex is not monitored in General, so nothing can run.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if !CodexCLIClient.isInstalled {
                Label("The codex CLI could not be found.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Picker("Start tasks when the window resets in", selection: codex.leadTimeMinutes) {
                ForEach(QueueAutoRunSettings.leadTimeOptions, id: \.self) { minutes in
                    Text("\(minutes) minutes").tag(minutes)
                }
            }
            Picker("Maximum tasks per window", selection: codex.maximumTasksPerWindow) {
                ForEach(QueueAutoRunSettings.maximumTasksOptions, id: \.self) { value in
                    Text("\(value)").tag(value)
                }
            }
            Picker("Maximum total runtime", selection: codex.maximumRuntimeMinutes) {
                ForEach(QueueAutoRunSettings.maximumRuntimeOptions, id: \.self) { value in
                    Text("\(value) minutes").tag(value)
                }
            }

            Text(codexWindowExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Everything else above applies to Codex too: the mode, quiet hours, the safety margin, the start delay, the quota floors, and every switch under Safety. Only these three are separate, because they are read against a different window.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!isEnabled)
    }

    private var codex: Binding<CodexAutoRunOverrides> {
        $settingsStore.settings.codexAutoRun
    }

    /// Says which window these figures will actually be measured against, since
    /// that is the whole reason the section exists — and it depends on the plan,
    /// so it is read from the live snapshot rather than asserted.
    private var codexWindowExplanation: String {
        let snapshot = usage.snapshot(for: .codex)
        if snapshot?.sessionWindow != nil {
            return "Your Codex plan reports a session window, so these are read against it the same way Claude's are."
        }
        if snapshot?.weeklyWindow != nil {
            return "Your Codex plan reports only a weekly window, so Tokenmax spends that one instead — a task starts in the lead time before the week resets. \"Per window\" then means per week, which is usually a reason to raise these two."
        }
        return "Codex reports a session window on some plans and only a weekly one on others. Tokenmax spends whichever is about to expire, so on a weekly-only plan \"per window\" means per week."
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
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

            // In preview mode the reasoning *is* the feature — the whole point
            // is watching the decision before trusting it — so it gets the full
            // picture rather than a one-line verdict.
            if settingsStore.settings.queueAutoRun.mode == .previewOnly,
               let taskID = autoRun.decision.taskID,
               let task = taskStore.tasks.first(where: { $0.id == taskID })
            {
                previewDetail(task)
            }

            if autoRun.isPausedAfterFailure {
                Button("Resume the queue") { autoRun.resumeAfterFailure() }
                    .font(.caption)
            }

            if let run = autoRun.lastRun {
                LabeledContent("Last run") {
                    Text(runSummary(run))
                        .font(.caption)
                        .multilineTextAlignment(.trailing)
                }
            }

            HStack {
                Button("Check eligibility") { autoRun.checkEligibility() }
                Button("Run next eligible task now") { confirmingRun = true }
                    .disabled(autoRun.activeRun != nil)
            }
            .font(.caption)
        }
    }

    private func previewDetail(_ task: TokenmaxTask) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Would run: \(task.title)")
                .font(.caption)
                .fontWeight(.medium)
            ForEach(previewLines(task), id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func previewLines(_ task: TokenmaxTask) -> [String] {
        var lines: [String] = []
        if let resetAt = usage.state.snapshot?.sessionWindow?.resetAt {
            lines.append("Session resets in \(RelativeTime.countdown(resetAt.timeIntervalSince(usage.tick)))")
        }
        if let estimate = task.estimatedMinutes {
            lines.append("Estimated \(estimate) min · limit \(task.maximumRuntimeMinutes) min")
        }
        if let session = usage.state.snapshot?.sessionWindow?.remainingPercent {
            lines.append("Session quota \(Int(session.rounded()))% remaining")
        }
        if let weekly = usage.state.snapshot?.weeklyWindow?.remainingPercent {
            lines.append("Weekly quota \(Int(weekly.rounded()))% remaining")
        }
        return lines
    }

    /// Reports this account's credit setting and what the switch does with it.
    ///
    /// Deliberately *not* the skip reason, which the Status section below
    /// already shows in full — two paragraphs saying the same thing in
    /// different words is how a settings pane becomes unreadable. This one
    /// answers "what is true of my account", the other "why did nothing run".
    ///
    /// Off is the default because the quota thresholds above already stop a run
    /// well short of the plan allowance, so this refuses runs that could never
    /// have been charged. It earns its place only as a categorical guard for
    /// anyone who does not trust the reported percentages.
    private var extraUsageDescription: String {
        let credits = usage.state.snapshot?.extraUsageEnabled
        let state = switch credits {
        case true: "Usage credits are enabled on this account."
        case false: "Usage credits are disabled on this account, so the plan allowance is already a hard stop."
        case nil: "Anthropic is not reporting whether usage credits are enabled."
        }
        guard settingsStore.settings.queueAutoRun.skipWhenExtraUsageEnabled else {
            return state + " Your quota thresholds above are what keep a run away from the plan allowance; switch this on for a guard that holds even if the reported percentages are wrong."
        }
        // An unknown is refused too, and a queue that never fires without
        // saying why is the state most easily mistaken for a broken app.
        return credits == false
            ? state + " Nothing is blocked."
            : state + " Nothing will run while this is on."
    }

    private var extraUsageBlocks: Bool {
        guard settingsStore.settings.queueAutoRun.skipWhenExtraUsageEnabled else { return false }
        return usage.state.snapshot?.extraUsageEnabled != false
    }

    private var statusIsNoteworthy: Bool {
        autoRun.decision.skipReason?.isNoteworthy ?? false
    }

    private var statusIcon: String {
        if autoRun.activeRun != nil { return "play.circle" }
        if autoRun.pendingRun != nil { return "timer" }
        return autoRun.decision.skipReason == nil ? "checkmark.circle" : "pause.circle"
    }

    private var statusText: String {
        if let run = autoRun.activeRun {
            return "Running \(run.taskTitle)… \(autoRun.progressText ?? "")"
        }
        if let pending = autoRun.pendingRun {
            return "Starting \(pending.taskTitle) in \(pending.secondsRemaining(now: usage.tick))s."
        }
        if autoRun.awaitingFreshUsage {
            return "Waiting for a fresh quota reading after the last task."
        }
        guard let reason = autoRun.decision.skipReason else {
            switch settingsStore.settings.queueAutoRun.mode {
            case .previewOnly: return "A task is eligible. Preview mode, so nothing will start."
            case .askBeforeRunning: return "A task is eligible and waiting for you to start it."
            case .automatic: return "A task is eligible."
            }
        }
        return reason.explanation
    }

    private func runSummary(_ run: TaskRunRecord) -> String {
        let time = run.startedAt.formatted(date: .abbreviated, time: .shortened)
        let duration = RelativeTime.short(run.duration())
        var parts = [time, run.taskTitle, run.status.displayName, duration]
        if let cost = run.costUSD { parts.append(String(format: "$%.3f", cost)) }
        return parts.joined(separator: " · ")
    }
}
