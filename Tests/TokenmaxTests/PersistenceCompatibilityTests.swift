import Foundation
import Testing

@testable import Tokenmax

/// Swift's synthesized `Codable` throws on a missing key instead of using the
/// property's default. Adding a single field therefore used to make every
/// existing file fail to decode — silently resetting settings and, worse,
/// discarding the entire task queue. These tests pin that shut.
@Suite("Persistence forward-compatibility")
struct PersistenceCompatibilityTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONStore.makeDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - Settings

    /// This is the exact shape that was on disk when the bug hit: a settings
    /// file written before `menuBarHighlightWhenReady` existed.
    @Test("Settings written by an older version still load")
    func loadsSettingsMissingNewKey() throws {
        let settings = try decode(AppSettings.self, """
        {
          "backgroundRefreshSeconds": 300,
          "foregroundRefreshSeconds": 60,
          "menuBarDisplayMode": "iconAndText",
          "playSound": false,
          "quietHours": { "enabled": false, "endMinutes": 420, "startMinutes": 1320 },
          "remindersEnabled": true,
          "sessionReminder": {
            "enabled": true, "leadTimeMinutes": 260, "minimumRemainingPercent": 5,
            "notifyOncePerWindow": true, "onlyWhenTasksQueued": false
          },
          "showBadge": true,
          "staleAfterSeconds": 600,
          "statuslineShimInstalled": false,
          "terminalApplication": "Terminal",
          "weeklyReminder": {
            "enabled": false, "leadTimeMinutes": 240, "minimumRemainingPercent": 20,
            "notifyOncePerWindow": true, "onlyWhenTasksQueued": true
          }
        }
        """)

        // The user's real values must survive…
        #expect(settings.remindersEnabled)
        #expect(settings.sessionReminder.leadTimeMinutes == 260)
        #expect(settings.sessionReminder.minimumRemainingPercent == 5)
        // …and the fields that did not exist yet take their defaults.
        #expect(settings.menuBarHighlightWhenReady)
        #expect(settings.showProjections)
        // Off by default would silently remove the queue from every existing
        // install on upgrade.
        #expect(settings.queueEnabled)
        // Upgrading must not repaint anyone's menu bar: the default is the
        // green the icon has always used, with no glow.
        #expect(settings.menuBarHighlightColor == .default)
        #expect(!settings.menuBarHighlightGlow)
        // Automation must never switch itself on during an upgrade, and must
        // start in the mode that cannot spend anything.
        #expect(!settings.queueAutoRun.enabled)
        #expect(settings.queueAutoRun.mode == .previewOnly)
        #expect(settings.menuBarProviderID == TokenmaxProvider.claudeCode.rawValue)
        #expect(!settings.codexAutoRunEnabled)
        // Both data sources default to on: an upgrade must not silently stop
        // monitoring a provider the user was already watching.
        #expect(settings.claudeCodeEnabled)
        #expect(settings.codexEnabled)
        // Keychain is what every existing install already does, and moving a
        // user to statusline-only would also silently pause their automation.
        #expect(settings.claudeDataSource == .keychain)
        // A queue built before Tokenmax could create Codex tasks was entirely
        // Claude's. The upgrade must not start pointing new tasks elsewhere.
        #expect(settings.defaultTaskProvider == .claudeCode)
        // nil means "whatever is in the user's own ~/.codex/config.toml", so a
        // new Codex task defers to the Codex they already configured.
        #expect(settings.defaultCodexModel == nil)
        #expect(settings.defaultCodexReasoningEffort == nil)
        #expect(settings.defaultCodexSandbox == CodexExecutionPolicy().sandbox)
        // Codex's own three figures start where Claude's do, so switching Codex
        // automation on is a decision about one agent, not a retune of both.
        #expect(settings.codexAutoRun == CodexAutoRunOverrides())
        #expect(settings.codexAutoRun.maximumTasksPerWindow == 1)
    }

    /// The Codex overrides must not be re-defaulted by a partial write: a file
    /// carrying only one of the three keeps that one and defaults the rest.
    @Test("A partly-written Codex override block keeps what it has")
    func partialCodexOverridesKeepTheirValues() throws {
        let settings = try decode(AppSettings.self, """
        { "codexAutoRunEnabled": true, "codexAutoRun": { "maximumTasksPerWindow": 5 } }
        """)

        #expect(settings.codexAutoRunEnabled)
        #expect(settings.codexAutoRun.maximumTasksPerWindow == 5)
        #expect(settings.codexAutoRun.leadTimeMinutes == CodexAutoRunOverrides().leadTimeMinutes)
        #expect(settings.codexAutoRun.maximumRuntimeMinutes == CodexAutoRunOverrides().maximumRuntimeMinutes)
    }

    /// The new-task defaults are the one place a bad value is copied onto every
    /// task made afterwards, so an unreadable one must cost that setting alone.
    @Test("An unreadable default provider costs that setting, not the file")
    func unreadableDefaultProviderKeepsTheRestOfTheFile() throws {
        let settings = try decode(AppSettings.self, """
        {
          "defaultTaskProvider": "gemini",
          "defaultCodexSandbox": "danger-full-access",
          "defaultTaskModel": "opus",
          "queueEnabled": false
        }
        """)

        #expect(settings.defaultTaskProvider == .claudeCode)
        #expect(settings.defaultCodexSandbox == CodexExecutionPolicy().sandbox)
        // The settings either side of the bad ones survived.
        #expect(settings.defaultTaskModel == "opus")
        #expect(!settings.queueEnabled)
    }

    @Test("The Codex new-task defaults survive a round trip")
    func codexDefaultsRoundTrip() throws {
        let settings = try decode(AppSettings.self, """
        {
          "defaultTaskProvider": "codex",
          "defaultCodexModel": "gpt-5.6-sol",
          "defaultCodexReasoningEffort": "xhigh",
          "defaultCodexSandbox": "workspace-write"
        }
        """)

        #expect(settings.defaultTaskProvider == .codex)
        #expect(settings.defaultCodexModel == "gpt-5.6-sol")
        #expect(settings.defaultCodexReasoningEffort == "xhigh")
        #expect(settings.defaultCodexSandbox == .workspaceWrite)
    }

    // MARK: - Model and thinking grade

    /// nil is "leave the flag off", which is the only value that keeps an
    /// existing task invoking the CLI exactly as it did.
    @Test("A task written before the thinking grade existed has none")
    func taskWithoutEffortDecodesToNil() throws {
        let task = try decode(TokenmaxTask.self, """
        {
          "title": "Old task", "prompt": "Do it",
          "autoRun": { "model": "opus", "maximumBudgetUSD": 1.0 },
          "codex": { "model": "gpt-test", "sandbox": "read-only" }
        }
        """)

        #expect(task.autoRun.model == "opus")
        #expect(task.autoRun.effort == nil)
        #expect(task.codex.reasoningEffort == nil)
        #expect(task.selectedEffort == nil)
    }

    // MARK: - Scheduled appointments

    /// nil is "use the ordinary burn schedule", which is what every task
    /// written before appointments existed means.
    @Test("A task written before scheduling existed has no appointment")
    func loadsTaskWithoutSchedule() throws {
        let task = try decode(TokenmaxTask.self, """
        { "title": "Old task", "prompt": "Do it", "estimatedMinutes": 20 }
        """)

        #expect(task.estimatedMinutes == 20)
        #expect(task.scheduledStart == nil)
    }

    @Test("An appointment survives a round trip")
    func scheduledStartRoundTrips() throws {
        var task = TokenmaxTask(title: "Friday burn", prompt: "Do it")
        let when = Date(timeIntervalSince1970: 1_785_600_000)
        task.scheduledStart = when

        let data = try JSONStore.makeEncoder().encode(task)
        let decoded = try JSONStore.makeDecoder().decode(TokenmaxTask.self, from: data)
        #expect(decoded.scheduledStart == when)
    }

    /// `RunTrigger` gained a case, and old state files must keep loading. An
    /// unknown trigger decodes as `.manual`, which is the value that keeps a
    /// mystery run *out* of the per-window automatic allowance.
    @Test("A run record with an unrecognised trigger decodes as manual")
    func unknownTriggerDecodesAsManual() throws {
        let record = try decode(TaskRunRecord.self, """
        {
          "taskID": "3E2E4E5A-0000-4000-8000-000000000001",
          "taskTitle": "From the future", "windowID": "w1", "trigger": "telepathy",
          "startedAt": "2026-08-07T09:00:00Z", "model": "sonnet",
          "workingDirectory": "/tmp", "status": "completed"
        }
        """)

        #expect(record.trigger == .manual)
        #expect(record.taskTitle == "From the future")
    }

    @Test("An automation block written before appointments keeps a grace period")
    func loadsAutoRunWithoutScheduleGrace() throws {
        let settings = try decode(AppSettings.self, """
        { "queueAutoRun": { "enabled": true, "startDelaySeconds": 60 } }
        """)

        #expect(settings.queueAutoRun.startDelaySeconds == 60)
        #expect(settings.queueAutoRun.scheduleGraceMinutes == QueueAutoRunSettings().scheduleGraceMinutes)
    }

    // MARK: - Usage credits

    /// An upgrade must not switch on a guard that stops the queue. The
    /// categorical credit refusal is opt-in — the quota thresholds are what
    /// keep a run clear of the plan allowance, and defaulting this on silently
    /// disabled automation for every account with credits enabled.
    @Test("An automation block written before the credit guard leaves it off")
    func loadsAutoRunWithoutCreditGuard() throws {
        let settings = try decode(AppSettings.self, """
        { "queueAutoRun": { "enabled": true, "mode": "automatic", "leadTimeMinutes": 60 } }
        """)

        #expect(settings.queueAutoRun.leadTimeMinutes == 60)
        #expect(!settings.queueAutoRun.skipWhenExtraUsageEnabled)
        // Switching it on must survive, or the option is not one.
        let explicit = try decode(AppSettings.self, """
        { "queueAutoRun": { "skipWhenExtraUsageEnabled": true } }
        """)
        #expect(explicit.queueAutoRun.skipWhenExtraUsageEnabled)
    }

    @Test("A task written before the quota watchdog existed gets it on")
    func loadsTaskWithoutQuotaWatchdog() throws {
        let task = try decode(TokenmaxTask.self, """
        {
          "title": "Old task", "prompt": "Do it",
          "autoRun": { "model": "opus", "allowShellCommands": true }
        }
        """)

        #expect(task.autoRun.allowShellCommands)
        #expect(task.autoRun.stopWhenQuotaExhausted)
    }

    /// The switch is only useful if "off" survives being written down — the
    /// whole point is a long-running task the user chose to let finish.
    @Test("Switching the quota watchdog off survives a round trip")
    func quotaWatchdogOffRoundTrips() throws {
        var task = TokenmaxTask(title: "Long job", prompt: "Do it")
        task.autoRun.stopWhenQuotaExhausted = false

        let data = try JSONStore.makeEncoder().encode(task)
        #expect(!(try JSONStore.makeDecoder().decode(TokenmaxTask.self, from: data)).autoRun.stopWhenQuotaExhausted)
    }

    // MARK: - Spend limit

    /// The editor's free-text field can be emptied or zeroed, and a hand-edited
    /// file can hold anything. `--max-budget-usd 0` is not a cheap run — the CLI
    /// rejects the flag, so the task fails instead. Anything non-positive has to
    /// come back as the default.
    @Test("A non-positive spend limit decodes as the default rather than as free")
    func nonPositiveBudgetFallsBackToDefault() throws {
        let zero = try decode(TokenmaxTask.self, """
        { "title": "Zero", "prompt": "Do it", "autoRun": { "maximumBudgetUSD": 0 } }
        """)
        let negative = try decode(TokenmaxTask.self, """
        { "title": "Sentinel", "prompt": "Do it", "autoRun": { "maximumBudgetUSD": -1 } }
        """)

        #expect(zero.autoRun.maximumBudgetUSD == TaskExecutionPolicy().maximumBudgetUSD)
        #expect(negative.autoRun.maximumBudgetUSD == TaskExecutionPolicy().maximumBudgetUSD)
        // The "Other…" sentinel must never be mistaken for a real budget.
        #expect(TaskExecutionPolicy.customBudgetTag < 0)
    }

    /// A figure typed into "Other…" is not in `budgetOptions` and must survive
    /// anyway — the old picker-only editor silently reset such values.
    @Test("A spend limit outside the preset list survives a round trip")
    func customBudgetRoundTrips() throws {
        var task = TokenmaxTask(title: "Burn", prompt: "Do it")
        task.autoRun.maximumBudgetUSD = 37.50

        let data = try JSONStore.makeEncoder().encode(task)
        let decoded = try JSONStore.makeDecoder().decode(TokenmaxTask.self, from: data)

        #expect(decoded.autoRun.maximumBudgetUSD == 37.50)
        #expect(!TaskExecutionPolicy.budgetOptions.contains(37.50))
    }

    @Test("Settings written before the default spend limit existed keep $0.50")
    func loadsSettingsWithoutDefaultBudget() throws {
        let settings = try decode(AppSettings.self, """
        { "defaultTaskModel": "opus" }
        """)

        #expect(settings.defaultTaskModel == "opus")
        // Upgrading must not raise anyone's per-task spending by itself.
        #expect(settings.defaultTaskBudgetUSD == TaskExecutionPolicy().maximumBudgetUSD)

        let zeroed = try decode(AppSettings.self, """
        { "defaultTaskBudgetUSD": 0 }
        """)
        #expect(zeroed.defaultTaskBudgetUSD == TaskExecutionPolicy().maximumBudgetUSD)
    }

    @Test("A pinned model id and thinking grade survive a round trip")
    func pinnedModelAndEffortRoundTrip() throws {
        var task = TokenmaxTask(title: "Pinned", prompt: "Do it")
        task.autoRun.model = "claude-opus-5"
        task.autoRun.effort = "xhigh"
        task.codex.reasoningEffort = "minimal"

        let data = try JSONStore.makeEncoder().encode(task)
        let decoded = try JSONStore.makeDecoder().decode(TokenmaxTask.self, from: data)

        #expect(decoded.autoRun.model == "claude-opus-5")
        #expect(decoded.autoRun.effort == "xhigh")
        #expect(decoded.codex.reasoningEffort == "minimal")
        // A pinned id is shown as typed, not run through `capitalized`.
        #expect(TaskExecutionPolicy.modelDisplayName("claude-opus-5") == "claude-opus-5")
    }

    /// The opener spends quota to open a window and nothing else, so it defaults
    /// to the cheapest grade rather than the CLI's own default.
    @Test("An opener written before the thinking grade takes the cheap default")
    func openerWithoutEffortTakesCheapDefault() throws {
        let settings = try decode(AppSettings.self, """
        { "sessionOpener": { "enabled": true, "model": "haiku" } }
        """)

        #expect(settings.sessionOpener.model == "haiku")
        #expect(settings.sessionOpener.effort == "low")
    }

    // MARK: - Data sources

    /// Zero enabled sources leaves nothing to draw and no clickable menu bar
    /// item to reach Settings through, so a hand-edited file has to be caught.
    @Test("A file with every data source switched off restores one")
    func allDataSourcesOffRestoresDefault() throws {
        let settings = try decode(AppSettings.self, """
        { "claudeCodeEnabled": false, "codexEnabled": false }
        """)

        #expect(settings.claudeCodeEnabled)
        #expect(!settings.codexEnabled)
        #expect(!settings.enabledProviders.isEmpty)
    }

    /// These two flags gate the whole app, so an undecodable value must cost
    /// the flag rather than throwing and resetting every other setting.
    @Test("A non-boolean data-source flag falls back instead of throwing")
    func malformedDataSourceFlagFallsBack() throws {
        let settings = try decode(AppSettings.self, """
        { "codexEnabled": "yes", "terminalApplication": "Ghostty" }
        """)

        #expect(settings.codexEnabled)
        #expect(settings.terminalApplication == "Ghostty")
    }

    /// The mode's whole point is not asking, so "off" — statusline-only — must
    /// survive being written down, and a value from the future must cost the
    /// setting rather than the file.
    @Test("The Claude data-source choice round-trips, and an unknown one falls back")
    func claudeDataSourceRoundTripsAndFallsBack() throws {
        var written = AppSettings()
        written.claudeDataSource = .statuslineOnly
        let data = try JSONStore.makeEncoder().encode(written)
        #expect(
            try JSONStore.makeDecoder().decode(AppSettings.self, from: data).claudeDataSource
                == .statuslineOnly
        )

        let unknown = try decode(AppSettings.self, """
        { "claudeDataSource": "telepathy", "remindersEnabled": true }
        """)
        #expect(unknown.claudeDataSource == .keychain)
        #expect(unknown.remindersEnabled)
    }

    /// Disabling hides rather than deletes: the rule has to be waiting when the
    /// provider is switched back on.
    @Test("Disabling a provider keeps its reminder rule")
    func disabledProviderKeepsItsReminderRule() throws {
        let settings = try decode(AppSettings.self, """
        {
          "codexEnabled": false,
          "codexWeeklyReminder": {
            "enabled": true, "leadTimeMinutes": 1440, "minimumRemainingPercent": 12,
            "notifyOncePerWindow": true, "onlyWhenTasksQueued": false
          }
        }
        """)

        #expect(!settings.codexEnabled)
        #expect(settings.codexWeeklyReminder.minimumRemainingPercent == 12)
        #expect(settings.reminderRule(for: .codex, kind: .weekly).leadTimeMinutes == 1440)
    }

    // MARK: - Queue automation

    @Test("A task written before automation existed keeps its defaults")
    func loadsTaskWithoutAutomationFields() throws {
        // The shape on disk before `autoRun` and the automation UI existed.
        let task = try decode(TokenmaxTask.self, """
        {
          "id": "8B1F5B3E-0000-4000-8000-000000000001",
          "title": "Refactor invoice validation",
          "prompt": "Clean up the validator.",
          "providerID": "claude-code",
          "priority": "high",
          "status": "ready",
          "executionMode": "manual",
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-01T00:00:00Z",
          "sortIndex": -3
        }
        """)

        #expect(task.title == "Refactor invoice validation")
        #expect(task.priority == .high)
        // Never inherit automation permission from an upgrade.
        #expect(task.executionMode == .manual)
        #expect(task.estimatedMinutes == nil)
        // Shell access is the one capability that can run arbitrary project
        // commands, so it must default off.
        #expect(!task.autoRun.allowShellCommands)
        #expect(task.autoRun.allowFileChanges)
        #expect(task.autoRun.maximumRuntimeMinutes == 15)
        #expect(task.provider == .claudeCode)
        #expect(task.codex.sandbox == .workspaceWrite)
    }

    @Test("A Codex task keeps its provider-specific sandbox policy")
    func preservesCodexPolicy() throws {
        let task = try decode(TokenmaxTask.self, """
        {
          "title": "Inspect app-server output", "prompt": "Inspect it.", "providerID": "codex",
          "codex": { "maximumRuntimeMinutes": 30, "model": "gpt-test", "sandbox": "read-only" }
        }
        """)

        #expect(task.provider == .codex)
        #expect(task.codex.maximumRuntimeMinutes == 30)
        #expect(task.codex.model == "gpt-test")
        #expect(task.codex.sandbox == .readOnly)
        #expect(task.maximumRuntimeMinutes == 30)
    }

    @Test("An unreadable execution mode degrades to manual")
    func unknownExecutionModeIsManual() throws {
        // A retired or hand-edited mode must cost that one field, never the
        // task — and must not read as permission to run unattended.
        let task = try decode(TokenmaxTask.self, """
        { "title": "Odd one", "prompt": "x", "executionMode": "someFutureMode" }
        """)
        #expect(task.executionMode == .manual)
    }

    /// These two shipped, so they are on real disks. Neither was ever read by
    /// the decision path — both behaved as `manual` — so decoding them as
    /// `manual` preserves the behaviour rather than changing it. The one thing
    /// that must not happen is either becoming `automatic`, which would start
    /// spending on tasks nobody approved for it.
    @Test("The retired execution modes decode as manual, never as automatic")
    func retiredExecutionModesAreManual() throws {
        for retired in ["askBeforeRunning", "approvedForSession"] {
            let task = try decode(TokenmaxTask.self, """
            { "title": "Upgraded", "prompt": "x", "executionMode": "\(retired)" }
            """)
            #expect(task.executionMode == .manual, "\(retired) must not survive as anything else")
        }
        // Two cases, so the picker and the guard cannot drift apart again.
        #expect(ExecutionMode.allCases.count == 2)
    }

    @Test("Auto-run settings written by an older version still load")
    func loadsPartialAutoRunSettings() throws {
        let settings = try decode(QueueAutoRunSettings.self, """
        { "enabled": true, "leadTimeMinutes": 60 }
        """)
        #expect(settings.enabled)
        #expect(settings.leadTimeMinutes == 60)
        // Absent keys take their defaults rather than throwing.
        #expect(settings.mode == .previewOnly)
        #expect(settings.maximumTasksPerWindow == 1)
        #expect(settings.pauseAfterFailure)
        #expect(settings.requireFreshUsageData)
        #expect(settings.resetBoundaryBehavior == .letTaskFinish)
    }

    @Test("An unreadable auto-run mode does not fall back to automatic")
    func unknownModeStaysSafe() throws {
        let settings = try decode(QueueAutoRunSettings.self, """
        { "enabled": true, "mode": "somethingElse" }
        """)
        #expect(settings.mode == .previewOnly)
    }

    @Test("A run record with an unreadable status is treated as interrupted")
    func unknownRunStatusNeedsAttention() throws {
        // Anything we cannot classify is something the user should look at —
        // it must not read as "finished and fine".
        let record = try decode(TaskRunRecord.self, """
        {
          "id": "8B1F5B3E-0000-4000-8000-000000000002",
          "taskID": "8B1F5B3E-0000-4000-8000-000000000003",
          "taskTitle": "Generate API tests",
          "windowID": "autorun-2026-01-01T00:00:00Z",
          "startedAt": "2026-01-01T00:00:00Z",
          "model": "sonnet",
          "workingDirectory": "/tmp",
          "status": "somethingNew"
        }
        """)
        #expect(record.status == .interrupted)
        // Absent trigger reads as manual, so a decode failure can never inflate
        // the automatic per-window count.
        #expect(record.trigger == .manual)
    }

    @Test("A run recorded before conversations were saved is not resumable")
    func olderRunsAreNotResumable() throws {
        // These records carry a session ID for a transcript the CLI discarded,
        // so trusting the ID would offer a reply that cannot work.
        let record = try decode(TaskRunRecord.self, """
        {
          "id": "8B1F5B3E-0000-4000-8000-000000000004",
          "taskID": "8B1F5B3E-0000-4000-8000-000000000005",
          "taskTitle": "Generate API tests",
          "windowID": "autorun-2026-01-01T00:00:00Z",
          "startedAt": "2026-01-01T00:00:00Z",
          "model": "sonnet",
          "workingDirectory": "/tmp",
          "status": "completed",
          "sessionID": "abc-123"
        }
        """)
        #expect(record.sessionID == "abc-123")
        #expect(!record.isResumable)
        #expect(record.replyText == nil)
    }

    @Test("Auto-run state written by an older version still loads")
    func loadsEmptyAutoRunState() throws {
        let state = try decode(QueueAutoRunState.self, "{}")
        #expect(state.runs.isEmpty)
        #expect(state.pausedWindowIDs.isEmpty)
    }

    @Test("A configured highlight colour survives a round trip")
    func highlightColourRoundTrips() throws {
        var written = AppSettings()
        written.menuBarHighlightColor = HighlightColor(red: 0.2, green: 0.6, blue: 1.0)
        written.menuBarHighlightGlow = true

        let data = try JSONStore.makeEncoder().encode(written)
        let read = try JSONStore.makeDecoder().decode(AppSettings.self, from: data)

        #expect(read.menuBarHighlightColor == written.menuBarHighlightColor)
        #expect(read.menuBarHighlightGlow)
    }

    /// The colour is the one setting a user is likely to hand-edit, since it is
    /// three plain numbers in the file.
    @Test("An out-of-range hand-edited colour is clamped, not rejected")
    func highlightColourClampsRatherThanThrowing() throws {
        let settings = try decode(AppSettings.self, """
        {
          "menuBarHighlightColor": { "red": 4.5, "green": -2, "blue": 0.5 },
          "remindersEnabled": true
        }
        """)

        #expect(settings.menuBarHighlightColor == HighlightColor(red: 1, green: 0, blue: 0.5))
        #expect(settings.remindersEnabled)
    }

    @Test("A partial colour keeps its other channels")
    func highlightColourAcceptsPartialObject() throws {
        let settings = try decode(AppSettings.self, #"{ "menuBarHighlightColor": { "blue": 0.9 } }"#)

        #expect(settings.menuBarHighlightColor.blue == 0.9)
        #expect(settings.menuBarHighlightColor.red == HighlightColor.default.red)
        #expect(settings.menuBarHighlightColor.green == HighlightColor.default.green)
    }

    /// Same guarantee as the retired enum case: one undecodable value costs the
    /// user that setting, never the whole file.
    @Test("A malformed colour falls back instead of throwing")
    func malformedHighlightColourFallsBack() throws {
        let settings = try decode(AppSettings.self, """
        { "menuBarHighlightColor": "green", "remindersEnabled": true }
        """)

        #expect(settings.menuBarHighlightColor == .default)
        #expect(settings.remindersEnabled)
    }

    /// A retired enum case must not take the whole settings file with it.
    @Test("An unrecognised display mode falls back instead of throwing")
    func unknownDisplayModeFallsBack() throws {
        let settings = try decode(AppSettings.self, """
        { "menuBarDisplayMode": "someRetiredMode", "remindersEnabled": true }
        """)

        #expect(settings.menuBarDisplayMode == .iconAndText)
        // The rest of the file survives rather than resetting to defaults.
        #expect(settings.remindersEnabled)
    }

    @Test("An almost-empty settings file loads as defaults")
    func loadsNearEmptySettings() throws {
        let settings = try decode(AppSettings.self, #"{ "remindersEnabled": true }"#)

        #expect(settings.remindersEnabled)
        #expect(settings.menuBarDisplayMode == .iconAndText)
        #expect(settings.terminalApplication == "Terminal")
    }

    @Test("A reminder rule missing a key keeps its other values")
    func loadsPartialReminderRule() throws {
        let settings = try decode(AppSettings.self, #"{ "sessionReminder": { "leadTimeMinutes": 45 } }"#)

        #expect(settings.sessionReminder.leadTimeMinutes == 45)
        #expect(settings.sessionReminder.enabled)
    }

    // MARK: - Tasks

    /// The severe case: a schema change must never drop the user's queue.
    @Test("Tasks written by an older version survive a schema change")
    func loadsTasksMissingNewKeys() throws {
        let file = try decode(TaskFile.self, """
        {
          "version": 1,
          "tasks": [
            {
              "id": "8A3E4F1C-0000-4000-8000-000000000001",
              "title": "Refactor invoice validation",
              "prompt": "Review the current validation flow.",
              "createdAt": "2026-07-31T09:00:00Z",
              "updatedAt": "2026-07-31T09:00:00Z"
            }
          ]
        }
        """)

        #expect(file.tasks.count == 1)
        let task = try #require(file.tasks.first)
        #expect(task.title == "Refactor invoice validation")
        // Everything absent falls back rather than throwing the task away.
        #expect(task.priority == .medium)
        #expect(task.status == .ready)
        #expect(task.executionMode == .manual)
        #expect(task.sortIndex == 0)
    }

    @Test("One malformed task does not take the whole queue with it")
    func toleratesSparseTask() throws {
        let file = try decode(TaskFile.self, #"{ "tasks": [ { "title": "Bare" } ] }"#)

        #expect(file.tasks.count == 1)
        #expect(file.tasks.first?.prompt == "")
    }

    @Test("A task file missing its version still loads")
    func loadsTaskFileWithoutVersion() throws {
        let file = try decode(TaskFile.self, #"{ "tasks": [] }"#)
        #expect(file.version == 1)
    }

    // MARK: - Notification state

    @Test("Notification state written by an older version still loads")
    func loadsPartialNotificationState() throws {
        let state = try decode(NotificationState.self, #"{ "firedIdentifiers": ["claude-session-x"] }"#)

        #expect(state.fired.count == 1)
        #expect(state.fired.first?.identifier == "claude-session-x")
        #expect(state.snoozeCounts.isEmpty)
    }

    /// A pre-fingerprint record cannot prove the rule is unchanged, so it
    /// re-arms rather than suppressing. Erring toward one duplicate banner beats
    /// silently swallowing a reminder the user has since reconfigured.
    @Test("Legacy fired records re-arm instead of suppressing")
    func legacyFiredRecordsRearm() throws {
        let state = try decode(NotificationState.self, #"{ "firedIdentifiers": ["claude-session-x"] }"#)

        #expect(!state.hasFired("claude-session-x", fingerprint: ReminderRule.sessionDefault.fingerprint))
    }

    @Test("Fingerprinted records round trip")
    func firedRecordsRoundTrip() throws {
        var state = NotificationState()
        let firedAt = Date(timeIntervalSince1970: 1_780_000_000)
        state.markFired("claude-session-x", fingerprint: "45|30.0|false", at: firedAt)

        let data = try JSONStore.makeEncoder().encode(state)
        let decoded = try JSONStore.makeDecoder().decode(NotificationState.self, from: data)

        #expect(decoded.hasFired("claude-session-x", fingerprint: "45|30.0|false"))
        #expect(decoded.firedAt("claude-session-x") == firedAt)
    }

    // MARK: - Session opener

    /// The same bug class as `menuBarHighlightWhenReady`: a settings file
    /// written before the session opener existed must keep every value the user
    /// set, and take the opener's defaults — which crucially means *off*.
    @Test("Settings written before the session opener still load, and it stays off")
    func loadsSettingsWithoutSessionOpener() throws {
        let settings = try decode(AppSettings.self, """
        {
          "remindersEnabled": true,
          "queueEnabled": false,
          "terminalApplication": "Ghostty"
        }
        """)

        #expect(settings.remindersEnabled)
        #expect(!settings.queueEnabled)
        #expect(settings.terminalApplication == "Ghostty")
        // A feature that spends quota must never arrive switched on.
        #expect(!settings.sessionOpener.enabled)
        #expect(settings.sessionOpener.delaySeconds == 60)
        #expect(settings.sessionOpener.model == "haiku")
        // The weekly threshold is what guards spending; the blanket
        // extra-usage refusal is opt-in, since it only ever duplicated that
        // guard and disabled the feature outright for anyone with credits on.
        #expect(!settings.sessionOpener.skipWhenExtraUsageEnabled)
        #expect(settings.sessionOpener.minimumWeeklyRemainingPercent == 10)
    }

    @Test("A partially-written session opener block keeps its defaults")
    func loadsPartialSessionOpener() throws {
        let settings = try decode(AppSettings.self, """
        { "sessionOpener": { "enabled": true, "delaySeconds": 120 } }
        """)

        #expect(settings.sessionOpener.enabled)
        #expect(settings.sessionOpener.delaySeconds == 120)
        #expect(settings.sessionOpener.minimumWeeklyRemainingPercent == 10)
        #expect(settings.sessionOpener.respectQuietHours)
    }

    /// `UsageSnapshot` uses synthesized `Codable`, which only tolerates an
    /// absent key when the property is optional. If `extraUsageEnabled` were
    /// ever made non-optional, every existing snapshot file would fail to load.
    @Test("A snapshot written before extraUsageEnabled still loads, as unknown")
    func loadsSnapshotWithoutExtraUsage() throws {
        let snapshot = try decode(UsageSnapshot.self, """
        {
          "providerID": "claude-code",
          "planName": "Pro",
          "windows": [],
          "fetchedAt": "2026-08-01T12:00:00Z",
          "fetchDuration": 0.2
        }
        """)

        #expect(snapshot.providerID == "claude-code")
        // Unknown, not "disabled" — the opener refuses on this.
        #expect(snapshot.extraUsageEnabled == nil)
        #expect(snapshot.availableResetCount == nil)
        #expect(snapshot.availableResetExpiresAt == nil)
    }

    @Test("Opener state written by an older version still loads")
    func loadsPartialOpenerState() throws {
        let state = try decode(SessionOpenerState.self, """
        { "attempts": [ { "cycleID": "opener-x", "startedAt": "2026-08-01T12:00:00Z" } ] }
        """)

        #expect(state.attempts.count == 1)
        #expect(state.lastKnownSessionResetAt == nil)
        #expect(state.forcedRefreshCycleIDs.isEmpty)
        // An unreadable outcome must not read as "still open for business".
        #expect(state.isSettled("opener-x"))
    }

    // MARK: - Round trip

    @Test("A failed save is reported to safety-critical callers")
    func reportsSaveFailure() throws {
        let parentFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmax-not-a-directory-\(UUID().uuidString)")
        try Data().write(to: parentFile)
        defer { try? FileManager.default.removeItem(at: parentFile) }

        let impossible = parentFile.appendingPathComponent("state.json")
        #expect(!JSONStore.save(AppSettings(), to: impossible))
    }

    @Test("Everything survives a full encode/decode round trip")
    func roundTrips() throws {
        var settings = AppSettings()
        settings.remindersEnabled = true
        settings.sessionReminder.leadTimeMinutes = 45
        settings.menuBarHighlightWhenReady = false
        settings.showProjections = false
        settings.queueEnabled = false
        settings.quietHours = QuietHours(enabled: true, startMinutes: 60, endMinutes: 120)

        let data = try JSONStore.makeEncoder().encode(settings)
        let decoded = try JSONStore.makeDecoder().decode(AppSettings.self, from: data)

        #expect(decoded == settings)

        var task = TokenmaxTask(title: "T", prompt: "P")
        task.priority = .urgent
        task.workingDirectory = "~/Projects/App"

        let taskData = try JSONStore.makeEncoder().encode(TaskFile(tasks: [task]))
        let decodedTasks = try JSONStore.makeDecoder().decode(TaskFile.self, from: taskData)

        let restored = try #require(decodedTasks.tasks.first)
        #expect(restored.id == task.id)
        #expect(restored.title == task.title)
        #expect(restored.prompt == task.prompt)
        #expect(restored.priority == task.priority)
        #expect(restored.workingDirectory == task.workingDirectory)
        // ISO-8601 encoding drops sub-second precision, which is irrelevant here
        // — compare to the second rather than pretending it round-trips exactly.
        #expect(abs(restored.createdAt.timeIntervalSince(task.createdAt)) < 1)
    }
}
