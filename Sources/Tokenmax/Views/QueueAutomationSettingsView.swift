import SwiftUI

struct QueueAutomationSettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var modelCatalog: ModelCatalogStore
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
                Text("When your session is close to resetting, Tokenmax can spend the quota that would otherwise expire by running a queued task you have approved. This runs Claude Code against a real project and can change files, which is why it is off by default and starts in preview mode.")
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

            // Not gated on `isEnabled`: these seed the task editor, which is
            // useful whether or not automatic execution is switched on.
            Section("New task defaults") {
                Picker("Model", selection: $settingsStore.settings.defaultTaskModel) {
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
                Picker("Thinking", selection: Binding(
                    get: { settingsStore.settings.defaultTaskEffort ?? "" },
                    set: { settingsStore.settings.defaultTaskEffort = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Default").tag("")
                    ForEach(modelCatalog.effortLevels(for: settingsStore.settings.defaultTaskModel), id: \.self) {
                        Text(TaskExecutionPolicy.effortDisplayName($0)).tag($0)
                    }
                }
                Picker("Spend limit", selection: $settingsStore.settings.defaultTaskBudgetUSD) {
                    ForEach(TaskExecutionPolicy.budgetOptions, id: \.self) { value in
                        Text(value == value.rounded()
                            ? String(format: "$%.0f", value)
                            : String(format: "$%.2f", value)
                        ).tag(value)
                    }
                }
                Text("What a new task starts with. All three are overridable per task, and changing them here leaves existing tasks alone. An alias like Opus always resolves to the newest model of that family; the list itself is fetched from Anthropic, so a new model appears without updating Tokenmax.")
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

                Text("Always enforced: one task at a time, never with unrestricted permissions, and never under an API key — only a Claude subscription. Each task's own tool permissions and spending limit are set when you edit it.")
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
        .onAppear { modelCatalog.refreshIfStale() }
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
            Text("This starts a real Claude Code run against the task's working directory using its own model, tool permissions, and spending limit. It ignores the schedule and quota thresholds so you can test outside a burn window — the directory, account, and per-task limits still apply.")
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

    /// Says what the toggle currently means for this account rather than
    /// restating it. "Not reported" is deliberately distinct from "disabled":
    /// an unknown is refused, and someone whose queue never fires needs to see
    /// that rather than guess at it.
    private var extraUsageDescription: String {
        let credits = usage.state.snapshot?.extraUsageEnabled
        guard settingsStore.settings.queueAutoRun.skipWhenExtraUsageEnabled else {
            return "Off, so tasks may run past the plan allowance and be charged as usage credits."
        }
        switch credits {
        case true:
            return "Usage credits are enabled on this account, so nothing will run. This is on by default because the queue exists to spend the tail of a window — exactly where the plan allowance ends and credits take over. Turn credits off at claude.ai, or switch this off to rely on the quota thresholds alone."
        case false:
            return "Usage credits are disabled on this account, so the plan allowance is a hard stop."
        case nil:
            return "Anthropic is not reporting whether usage credits are enabled, so nothing will run. An unreported setting is treated as unsafe."
        }
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
