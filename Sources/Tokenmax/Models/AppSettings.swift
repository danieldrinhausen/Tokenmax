import Foundation

enum MenuBarDisplayMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case iconOnly
    case textOnly
    case iconAndText

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .iconOnly: "Bars only"
        case .textOnly: "Time remaining only"
        case .iconAndText: "Bars + time remaining"
        }
    }
}

/// One reminder rule per usage window. Session and weekly are configured
/// independently, as the spec requires.
struct ReminderRule: Codable, Sendable, Equatable {
    var enabled: Bool
    /// Minutes before reset to fire.
    var leadTimeMinutes: Int
    /// Only notify if at least this much quota remains — the point is to warn
    /// about quota that is about to be *wasted*, not quota already spent.
    var minimumRemainingPercent: Double
    var onlyWhenTasksQueued: Bool
    var notifyOncePerWindow: Bool

    init(
        enabled: Bool,
        leadTimeMinutes: Int,
        minimumRemainingPercent: Double,
        onlyWhenTasksQueued: Bool,
        notifyOncePerWindow: Bool
    ) {
        self.enabled = enabled
        self.leadTimeMinutes = leadTimeMinutes
        self.minimumRemainingPercent = minimumRemainingPercent
        self.onlyWhenTasksQueued = onlyWhenTasksQueued
        self.notifyOncePerWindow = notifyOncePerWindow
    }

    /// Lenient: a key added in a later version must not invalidate a file
    /// written by an earlier one. See `AppSettings.init(from:)`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ReminderRule.sessionDefault
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled
        leadTimeMinutes = try container.decodeIfPresent(Int.self, forKey: .leadTimeMinutes) ?? fallback.leadTimeMinutes
        minimumRemainingPercent = try container.decodeIfPresent(Double.self, forKey: .minimumRemainingPercent)
            ?? fallback.minimumRemainingPercent
        onlyWhenTasksQueued = try container.decodeIfPresent(Bool.self, forKey: .onlyWhenTasksQueued)
            ?? fallback.onlyWhenTasksQueued
        notifyOncePerWindow = try container.decodeIfPresent(Bool.self, forKey: .notifyOncePerWindow)
            ?? fallback.notifyOncePerWindow
    }

    /// The fields that decide *when* and *whether* this rule fires, recorded
    /// alongside a delivered reminder.
    ///
    /// Without this, "notify once per window" keys only on the window: a
    /// reminder sent under a 4-hour lead time keeps suppressing the window
    /// after the user changes the lead to 45 minutes, and the app looks broken
    /// while behaving exactly as configured. Including these fields means a
    /// material rule change re-arms the current window.
    ///
    /// `notifyOncePerWindow` is deliberately excluded — toggling the dedup
    /// switch is not a new intent about *when* to fire.
    var fingerprint: String {
        "\(leadTimeMinutes)|\(minimumRemainingPercent)|\(onlyWhenTasksQueued)"
    }

    static let sessionDefault = ReminderRule(
        enabled: true,
        leadTimeMinutes: 30,
        minimumRemainingPercent: 20,
        onlyWhenTasksQueued: true,
        notifyOncePerWindow: true
    )

    static let weeklyDefault = ReminderRule(
        enabled: false,
        leadTimeMinutes: 240,
        minimumRemainingPercent: 20,
        onlyWhenTasksQueued: true,
        notifyOncePerWindow: true
    )

    /// Codex gets its own weekly default rather than sharing Claude's. The two
    /// weeks are different lengths of rope — reusing one threshold would be
    /// wrong for whichever provider it was not tuned for. Off by default, like
    /// every other reminder that was not already switched on.
    static let codexWeeklyDefault = ReminderRule(
        enabled: false,
        leadTimeMinutes: 240,
        minimumRemainingPercent: 20,
        onlyWhenTasksQueued: true,
        notifyOncePerWindow: true
    )

    /// A rule that can never fire, for windows a provider does not report.
    static let disabled = ReminderRule(
        enabled: false,
        leadTimeMinutes: 0,
        minimumRemainingPercent: 0,
        onlyWhenTasksQueued: false,
        notifyOncePerWindow: true
    )
}

struct QuietHours: Codable, Sendable, Equatable {
    var enabled: Bool = false
    /// Minutes from midnight.
    var startMinutes: Int = 22 * 60
    var endMinutes: Int = 7 * 60

    init(enabled: Bool = false, startMinutes: Int = 22 * 60, endMinutes: Int = 7 * 60) {
        self.enabled = enabled
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        startMinutes = try container.decodeIfPresent(Int.self, forKey: .startMinutes) ?? 22 * 60
        endMinutes = try container.decodeIfPresent(Int.self, forKey: .endMinutes) ?? 7 * 60
    }

    /// Handles windows that wrap past midnight (22:00 → 07:00).
    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if startMinutes == endMinutes { return false }
        if startMinutes < endMinutes {
            return minutes >= startMinutes && minutes < endMinutes
        }
        return minutes >= startMinutes || minutes < endMinutes
    }
}

/// The opt-in session opener: after the five-hour window expires, send one
/// minimal non-interactive prompt so a fresh window becomes active.
///
/// Off by default, because unlike everything else in Tokenmax this deliberately
/// *spends* quota. Two conditions are deliberately absent: tools are always
/// fully disabled and subscription authentication is always required. Both are
/// invariants of the feature — a switch for either would only offer a way to
/// turn the safety off.
struct SessionOpenerSettings: Codable, Sendable, Equatable {
    var enabled: Bool = false
    /// Grace after the reset before opening. Not a correctness requirement —
    /// margin against racing the endpoint's own window bookkeeping.
    var delaySeconds: Int = 60
    /// Refuse to spend when the weekly allowance is this low. The five-hour and
    /// weekly limits share the same budget, so an opener is never free.
    var minimumWeeklyRemainingPercent: Double = 10
    var model: String = "haiku"
    /// The opener exists to spend the *minimum* quota that opens a window, so
    /// it defaults to the cheapest thinking grade rather than the CLI's own
    /// default. Passed as `--effort`; nil leaves the flag off.
    var effort: String? = "low"
    /// A window opened at 03:00 expires before the user wakes up.
    var respectQuietHours: Bool = true
    /// Extra usage lets spending continue past the plan allowance as a real
    /// charge — but only *past* it, and the opener only ever runs into a window
    /// that has just reset with the weekly allowance above the threshold above.
    /// Reaching a charge from there is not possible, so this defaults off: as a
    /// blanket refusal it disabled the whole feature for anyone who happens to
    /// have credits switched on, which is a normal thing to have.
    ///
    /// Kept as an option because it is categorical where the threshold is
    /// numeric — it holds even if the reported percentages are wrong.
    var skipWhenExtraUsageEnabled: Bool = false
    var verifyAfterRun: Bool = true

    static let modelOptions = ["haiku", "sonnet"]
    static let delayOptions = [30, 60, 120, 300]
    static let weeklyThresholdOptions = [5.0, 10.0, 20.0, 30.0]
    static let effortOptions = TaskExecutionPolicy.effortOptions

    static func modelDisplayName(_ raw: String) -> String {
        switch raw {
        case "haiku": "Haiku"
        case "sonnet": "Sonnet"
        default: raw
        }
    }

    init() {}

    /// Lenient for the same reason as `AppSettings.init(from:)` — see there.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = SessionOpenerSettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        delaySeconds = try container.decodeIfPresent(Int.self, forKey: .delaySeconds) ?? d.delaySeconds
        minimumWeeklyRemainingPercent = try container.decodeIfPresent(
            Double.self, forKey: .minimumWeeklyRemainingPercent
        ) ?? d.minimumWeeklyRemainingPercent
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? d.model
        // An opener written before `effort` existed keeps the cheap default,
        // which is what it was implicitly getting from the picker anyway.
        effort = try container.decodeIfPresent(String.self, forKey: .effort) ?? d.effort
        respectQuietHours = try container.decodeIfPresent(Bool.self, forKey: .respectQuietHours)
            ?? d.respectQuietHours
        skipWhenExtraUsageEnabled = try container.decodeIfPresent(Bool.self, forKey: .skipWhenExtraUsageEnabled)
            ?? d.skipWhenExtraUsageEnabled
        verifyAfterRun = try container.decodeIfPresent(Bool.self, forKey: .verifyAfterRun) ?? d.verifyAfterRun
    }
}

struct AppSettings: Codable, Sendable, Equatable {
    /// Retained for compatibility with older settings. The current interface
    /// keeps the compact menu-bar meter on Claude Code.
    var menuBarProviderID: String = TokenmaxProvider.claudeCode.rawValue
    /// Bars plus the session countdown. The bars carry "how much is left"; the
    /// countdown carries "how long to spend it", which the bars cannot show.
    /// The old percentage readout duplicated the bars and was dropped.
    var menuBarDisplayMode: MenuBarDisplayMode = .iconAndText

    /// Which quota each bar of the icon draws, top to bottom. Two or three bars;
    /// see `MenuBarBars`.
    var menuBarBars: MenuBarBars = .default

    /// Which window the "time remaining" text counts down to.
    ///
    /// Independent of `menuBarBars` on purpose: the most useful deadline is not
    /// always one the bars have room for, and tying the two would mean changing
    /// the icon to change the text. `menuBarDisplayMode` still decides whether
    /// the text appears at all.
    var menuBarCountdownSource: MenuBarQuotaSource = .claudeSession

    /// UI tick while the popover is open. Network calls are separately floored
    /// at 180s inside `ClaudeOAuthUsageClient`, so this is safe to keep low.
    var foregroundRefreshSeconds: TimeInterval = 60
    var backgroundRefreshSeconds: TimeInterval = 300
    var staleAfterSeconds: TimeInterval = 600

    var remindersEnabled: Bool = false
    var sessionReminder: ReminderRule = .sessionDefault
    var weeklyReminder: ReminderRule = .weeklyDefault
    /// Codex's weekly window, configured independently of Claude's. See
    /// `ReminderRule.codexWeeklyDefault`.
    var codexWeeklyReminder: ReminderRule = .codexWeeklyDefault
    var quietHours: QuietHours = .init()
    var playSound: Bool = false
    var showBadge: Bool = true

    /// Light the menubar icon while the session window is in its "spend it now"
    /// stretch. Independent of `remindersEnabled` so the visual cue works even
    /// with notifications switched off. Off means the icon stays a plain
    /// template at all times — no colour, no glow, no in-popover banner tint.
    var menuBarHighlightWhenReady: Bool = true

    /// What colour that highlight is. Configurable because green is not a
    /// neutral choice: it collides with other menu bar items on some setups, it
    /// is the least distinguishable hue for the most common colour-vision
    /// deficiency, and "quota available" is not universally green to begin with.
    var menuBarHighlightColor: HighlightColor = .default

    /// Add a bloom around the lit bars. Off by default — it is a taste call, and
    /// the plain colour swap is the quieter of the two.
    var menuBarHighlightGlow: Bool = false

    /// Show the measured pace under each window: how much quota it needs before
    /// the reset, and whether that leaves a reserve or runs out early.
    var showProjections: Bool = true

    /// The whole task-queue feature: the queue window, the popover's queue
    /// section, the dock badge, and the queue-related banner actions. Turning it
    /// off leaves Tokenmax a pure quota meter.
    ///
    /// Tasks already on disk are left untouched — this hides the feature, it
    /// does not delete anything.
    var queueEnabled: Bool = true

    /// Whether Tokenmax asks GitHub once a day if there is a newer release.
    ///
    /// On by default, and worth a switch anyway: it is the only request the app
    /// makes to a host unrelated to the quota it exists to read, and somebody
    /// running this on a locked-down machine should be able to say no without
    /// giving up the app. Off means no request is made at all — not a request
    /// whose answer is ignored.
    var checkForUpdates: Bool = true

    var terminalApplication: String = "Terminal"
    var statuslineShimInstalled: Bool = false

    /// Where the Claude numbers come from — the keychain-backed endpoint, or
    /// the status line alone. See `ClaudeDataSource` for why this exists.
    ///
    /// Keychain by default, including for someone upgrading: it is the
    /// behaviour every existing install already has, and silently moving a
    /// user to statusline-only would also silently pause their automation.
    var claudeDataSource: ClaudeDataSource = .keychain

    /// See `SessionOpenerSettings`. Off by default.
    var sessionOpener: SessionOpenerSettings = .init()

    /// See `QueueAutoRunSettings`. Off by default, and in preview mode even
    /// once switched on. Deliberately separate from `sessionReminder` and
    /// `sessionOpener`: the three features must not share enablement or
    /// silently retune each other.
    var queueAutoRun: QueueAutoRunSettings = .init()
    /// Codex needs an independent opt-in: a user who previously enabled
    /// Claude automation must never gain a second unattended agent on upgrade.
    var codexAutoRunEnabled: Bool = false
    /// See `CodexAutoRunOverrides`. The handful of `queueAutoRun` figures that
    /// mean something different against Codex's windows.
    var codexAutoRun: CodexAutoRunOverrides = .init()

    /// Whether each provider is monitored at all. Switching one off stops its
    /// polling, hides its popover section and menu-bar bars, cancels its pending
    /// reminders, and refuses to auto-run its tasks.
    ///
    /// Like `queueEnabled`, these hide rather than delete: the provider's
    /// reminder rules, bar layout, and tasks all stay on disk, so switching it
    /// back on restores the user's own arrangement instead of a rebuilt one.
    var claudeCodeEnabled: Bool = true
    var codexEnabled: Bool = true

    /// Which provider a new task is created for.
    ///
    /// Claude by default, including for someone upgrading: a task queue built
    /// before Tokenmax could create Codex tasks was entirely Claude's, and the
    /// upgrade must not quietly start pointing new tasks at a second agent.
    var defaultTaskProvider: TokenmaxProvider = .claudeCode

    /// Seeded into a new task's policy so the common choice is made once rather
    /// than on every task. All are overridable per task in the editor, and none
    /// affects a task already on disk.
    var defaultTaskModel: String = "sonnet"
    var defaultTaskEffort: String?

    /// The Codex half of the same idea. nil model and effort mean "whatever is
    /// in the user's own `~/.codex/config.toml`", which is the right default:
    /// someone who configured Codex once should not have to configure it again
    /// here. The sandbox has no such source, so it takes the policy default.
    var defaultCodexModel: String?
    var defaultCodexReasoningEffort: String?
    var defaultCodexSandbox: CodexSandbox = CodexExecutionPolicy().sandbox
    /// Matches `TaskExecutionPolicy`'s own default, so leaving this alone
    /// changes nothing. It exists because someone who works in $20 tasks was
    /// otherwise retyping the figure on every single one.
    var defaultTaskBudgetUSD: Double = 0.50

    static let terminalOptions = ["Terminal", "Ghostty", "iTerm", "Warp", "Alacritty", "kitty"]

    func isEnabled(_ provider: TokenmaxProvider) -> Bool {
        switch provider {
        case .claudeCode: claudeCodeEnabled
        case .codex: codexEnabled
        }
    }

    /// Never empty — `init(from:)` guarantees at least one provider stays on.
    var enabledProviders: [TokenmaxProvider] {
        TokenmaxProvider.allCases.filter(isEnabled)
    }

    /// The menu-bar quotas a disabled provider must not be able to claim. This
    /// is the set every bar-editing call site passes as `allowed:`.
    var allowedMenuBarSources: [MenuBarQuotaSource] {
        MenuBarQuotaSource.allCases.filter { isEnabled($0.provider) }
    }

    /// The stored layout, normalized for display.
    ///
    /// Read-time only: `menuBarBars` on disk is never rewritten by this, which
    /// is what lets a disabled provider's slot survive until it is switched back
    /// on. Everything that *draws* the icon goes through here; everything that
    /// *edits* it works on `menuBarBars` directly.
    var effectiveMenuBarBars: MenuBarBars {
        MenuBarBars(menuBarBars.sources, allowed: allowedMenuBarSources)
    }

    /// nil is unreachable in practice — `allowedMenuBarSources` is non-empty
    /// whenever a provider is enabled — but the countdown is optional anyway,
    /// so there is nothing to force here.
    var effectiveCountdownSource: MenuBarQuotaSource? {
        isEnabled(menuBarCountdownSource.provider)
            ? menuBarCountdownSource
            : allowedMenuBarSources.first
    }

    /// The one place that maps a window to the rule governing it. Every caller
    /// went through `kind == .session ? … : …` before Codex existed, which
    /// quietly gave Codex's week Claude's thresholds.
    func reminderRule(for provider: TokenmaxProvider, kind: UsageWindowKind) -> ReminderRule {
        switch (provider, kind) {
        case (.claudeCode, .session): sessionReminder
        case (.claudeCode, .weekly): weeklyReminder
        case (.codex, .weekly): codexWeeklyReminder
        // Codex reports no session window, and no provider reports a
        // model-specific weekly to remind about.
        default: .disabled
        }
    }

    init() {}

    /// Swift's synthesized `Codable` throws on a missing key rather than
    /// falling back to the property's default. That means simply *adding* a
    /// setting in a new version would make every existing `settings.json` fail
    /// to decode, silently resetting the user's entire configuration. Decoding
    /// each key independently keeps old files readable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()

        // `decodeIfPresent` returns nil only for an absent or null key — a
        // *present* value that no longer matches a case throws, which would
        // take the whole settings file down with it. `try?` catches that too,
        // so retiring an enum case can never reset the user's configuration.
        menuBarDisplayMode = (try? container.decodeIfPresent(MenuBarDisplayMode.self, forKey: .menuBarDisplayMode))
            ?? d.menuBarDisplayMode
        menuBarProviderID = try container.decodeIfPresent(String.self, forKey: .menuBarProviderID)
            ?? d.menuBarProviderID
        foregroundRefreshSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .foregroundRefreshSeconds)
            ?? d.foregroundRefreshSeconds
        backgroundRefreshSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .backgroundRefreshSeconds)
            ?? d.backgroundRefreshSeconds
        staleAfterSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .staleAfterSeconds)
            ?? d.staleAfterSeconds
        remindersEnabled = try container.decodeIfPresent(Bool.self, forKey: .remindersEnabled) ?? d.remindersEnabled
        sessionReminder = try container.decodeIfPresent(ReminderRule.self, forKey: .sessionReminder) ?? d.sessionReminder
        weeklyReminder = try container.decodeIfPresent(ReminderRule.self, forKey: .weeklyReminder) ?? d.weeklyReminder
        codexWeeklyReminder = try container.decodeIfPresent(ReminderRule.self, forKey: .codexWeeklyReminder)
            ?? d.codexWeeklyReminder
        // `try?` as above: `MenuBarBars` normalizes what it can, but a value of
        // the wrong shape entirely still has to fall back rather than throw.
        menuBarBars = (try? container.decodeIfPresent(MenuBarBars.self, forKey: .menuBarBars)) ?? d.menuBarBars
        menuBarCountdownSource = (try? container.decodeIfPresent(
            MenuBarQuotaSource.self, forKey: .menuBarCountdownSource
        )) ?? d.menuBarCountdownSource
        quietHours = try container.decodeIfPresent(QuietHours.self, forKey: .quietHours) ?? d.quietHours
        playSound = try container.decodeIfPresent(Bool.self, forKey: .playSound) ?? d.playSound
        showBadge = try container.decodeIfPresent(Bool.self, forKey: .showBadge) ?? d.showBadge
        menuBarHighlightWhenReady = try container.decodeIfPresent(Bool.self, forKey: .menuBarHighlightWhenReady)
            ?? d.menuBarHighlightWhenReady
        // `try?` for the same reason as `menuBarDisplayMode` above: a colour
        // hand-edited into something undecodable must cost the user that one
        // setting, not the whole file.
        menuBarHighlightColor = (try? container.decodeIfPresent(HighlightColor.self, forKey: .menuBarHighlightColor))
            ?? d.menuBarHighlightColor
        menuBarHighlightGlow = try container.decodeIfPresent(Bool.self, forKey: .menuBarHighlightGlow)
            ?? d.menuBarHighlightGlow
        showProjections = try container.decodeIfPresent(Bool.self, forKey: .showProjections) ?? d.showProjections
        queueEnabled = try container.decodeIfPresent(Bool.self, forKey: .queueEnabled) ?? d.queueEnabled
        checkForUpdates = try container.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? d.checkForUpdates
        terminalApplication = try container.decodeIfPresent(String.self, forKey: .terminalApplication)
            ?? d.terminalApplication
        statuslineShimInstalled = try container.decodeIfPresent(Bool.self, forKey: .statuslineShimInstalled)
            ?? d.statuslineShimInstalled
        // `try?` so an unrecognised value costs this one setting, not the
        // file — and the fallback is keychain, the mode whose failure modes
        // (a consent dialog) are annoying rather than silent.
        claudeDataSource = (try? container.decodeIfPresent(ClaudeDataSource.self, forKey: .claudeDataSource))
            ?? d.claudeDataSource
        sessionOpener = try container.decodeIfPresent(SessionOpenerSettings.self, forKey: .sessionOpener)
            ?? d.sessionOpener
        queueAutoRun = try container.decodeIfPresent(QueueAutoRunSettings.self, forKey: .queueAutoRun)
            ?? d.queueAutoRun
        codexAutoRunEnabled = try container.decodeIfPresent(Bool.self, forKey: .codexAutoRunEnabled)
            ?? d.codexAutoRunEnabled
        codexAutoRun = try container.decodeIfPresent(CodexAutoRunOverrides.self, forKey: .codexAutoRun)
            ?? d.codexAutoRun
        // `try?` rather than the plain-`try` form the other Bools use. These two
        // gate the whole app, and a hand-edited `"codexEnabled": "yes"` under
        // plain `try` would throw out of this initializer, make `JSONStore.load`
        // return nil, and reset every other setting with it.
        claudeCodeEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .claudeCodeEnabled))
            ?? d.claudeCodeEnabled
        codexEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .codexEnabled)) ?? d.codexEnabled
        // `try?` for the same reason as the two above: an unrecognised provider
        // name must cost this one setting, not the whole settings file.
        defaultTaskProvider = (try? container.decodeIfPresent(TokenmaxProvider.self, forKey: .defaultTaskProvider))
            ?? d.defaultTaskProvider
        defaultTaskModel = try container.decodeIfPresent(String.self, forKey: .defaultTaskModel)
            ?? d.defaultTaskModel
        defaultTaskEffort = try container.decodeIfPresent(String.self, forKey: .defaultTaskEffort)
        defaultCodexModel = try container.decodeIfPresent(String.self, forKey: .defaultCodexModel)
        defaultCodexReasoningEffort = try container.decodeIfPresent(
            String.self, forKey: .defaultCodexReasoningEffort
        )
        defaultCodexSandbox = (try? container.decodeIfPresent(CodexSandbox.self, forKey: .defaultCodexSandbox))
            ?? d.defaultCodexSandbox
        // Same guard as `TaskExecutionPolicy.init(from:)`: a non-positive figure
        // here would seed every new task with a budget the CLI refuses.
        let defaultBudget = try container.decodeIfPresent(Double.self, forKey: .defaultTaskBudgetUSD)
            ?? d.defaultTaskBudgetUSD
        defaultTaskBudgetUSD = defaultBudget > 0 ? defaultBudget : d.defaultTaskBudgetUSD
        // A file with every source off has no meter to draw and no clickable
        // menu bar item to reach Settings through. The UI prevents this; a
        // hand-edited file has to be caught here instead of booting invisible.
        if !claudeCodeEnabled && !codexEnabled { claudeCodeEnabled = true }
    }
}

/// One delivered reminder.
struct FiredReminder: Codable, Sendable, Equatable {
    var identifier: String
    var firedAt: Date
    /// `ReminderRule.fingerprint` at the moment of delivery. Empty for records
    /// written before fingerprinting existed.
    var ruleFingerprint: String

    init(identifier: String, firedAt: Date = Date(), ruleFingerprint: String) {
        self.identifier = identifier
        self.firedAt = firedAt
        self.ruleFingerprint = ruleFingerprint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decodeIfPresent(String.self, forKey: .identifier) ?? ""
        firedAt = try container.decodeIfPresent(Date.self, forKey: .firedAt) ?? .distantPast
        ruleFingerprint = try container.decodeIfPresent(String.self, forKey: .ruleFingerprint) ?? ""
    }
}

/// Persisted so "notify once per window" survives relaunches.
struct NotificationState: Codable, Sendable {
    var fired: [FiredReminder] = []
    var snoozeCounts: [String: Int] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snoozeCounts = try container.decodeIfPresent([String: Int].self, forKey: .snoozeCounts) ?? [:]

        if let records = try container.decodeIfPresent([FiredReminder].self, forKey: .fired) {
            fired = records
            return
        }

        // Pre-fingerprint files stored bare identifier strings. Carry them over
        // with an empty fingerprint, which `hasFired` reads as "rule unknown".
        let legacy = try container.decodeIfPresent([String].self, forKey: .firedIdentifiers) ?? []
        fired = legacy.map {
            FiredReminder(identifier: $0, firedAt: .distantPast, ruleFingerprint: "")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case fired
        case snoozeCounts
        /// Legacy, read-only.
        case firedIdentifiers
    }

    /// Written explicitly because `firedIdentifiers` is a decode-only key —
    /// there is no property behind it for the compiler to synthesize from, and
    /// the old array is deliberately not written back out.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fired, forKey: .fired)
        try container.encode(snoozeCounts, forKey: .snoozeCounts)
    }

    mutating func markFired(_ identifier: String, fingerprint: String, at date: Date = Date()) {
        let record = FiredReminder(identifier: identifier, firedAt: date, ruleFingerprint: fingerprint)

        if let index = fired.firstIndex(where: { $0.identifier == identifier }) {
            fired[index] = record
        } else {
            fired.append(record)
        }

        // Old window identifiers are worthless once the window is long gone.
        if fired.count > 200 {
            fired.removeFirst(fired.count - 200)
        }
    }

    mutating func clearFired(_ identifier: String) {
        fired.removeAll { $0.identifier == identifier }
    }

    func firedAt(_ identifier: String) -> Date? {
        guard let record = fired.first(where: { $0.identifier == identifier }),
              record.firedAt != .distantPast
        else { return nil }
        return record.firedAt
    }

    /// A window counts as already notified only while the rule that produced the
    /// reminder is still in effect.
    ///
    /// A record with no fingerprint predates this check. It is treated as "rule
    /// unknown" and re-arms rather than suppresses: this identifier is only ever
    /// queried for the *current* window, so the worst case is a single duplicate
    /// banner after upgrading mid-window — against silently swallowing a
    /// reminder the user has since reconfigured, which is the failure that
    /// prompted this.
    func hasFired(_ identifier: String, fingerprint: String) -> Bool {
        guard let record = fired.first(where: { $0.identifier == identifier }) else { return false }
        guard !record.ruleFingerprint.isEmpty else { return false }
        return record.ruleFingerprint == fingerprint
    }
}
