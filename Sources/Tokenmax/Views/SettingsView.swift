import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general
    case notifications
    case sessionOpener
    case queueAutomation
    case dataSource

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .notifications: "Notifications"
        case .sessionOpener: "Session Opener"
        case .queueAutomation: "Queue Automation"
        case .dataSource: "Data Source"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .notifications: "bell"
        case .sessionOpener: "bolt.badge.clock"
        case .queueAutomation: "play.circle"
        case .dataSource: "antenna.radiowaves.left.and.right"
        }
    }
}

/// A sidebar rather than a tab bar.
///
/// Four tabs did not fit the window's width, so macOS silently collapsed them
/// into a `»` overflow menu — the Session Opener pane was reachable only by
/// discovering a chevron. A sidebar has room for the names, scales to further
/// sections without re-tuning the width, and keeps the current section visible
/// while you are in it.
struct SettingsView: View {
    /// Optional because `List` selection is; the detail pane falls back to
    /// General so an empty selection can never blank the window.
    @State private var selection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, id: \.self, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
                    .padding(.vertical, 2)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 168, ideal: 178, max: 220)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Nothing here benefits from collapsing the sidebar, and a half-hidden
        // navigation is the problem this replaced.
        .toolbar(removing: .sidebarToggle)
        .navigationSplitViewStyle(.balanced)
        .frame(width: 720, height: 600)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .general {
        case .general: GeneralSettingsView()
        case .notifications: NotificationSettingsView()
        case .sessionOpener: SessionOpenerSettingsView()
        case .queueAutomation: QueueAutomationSettingsView()
        case .dataSource: DataSourceSettingsView()
        }
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var usage: ProviderUsageCoordinator

    @StateObject private var loginItem = LoginItemService()

    var body: some View {
        Form {
            Section {
                Toggle("Start Tokenmax at login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))

                if let explanation = loginItem.statusExplanation {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(explanation)
                            .font(.caption)
                            .foregroundStyle(.orange)
                        if loginItem.needsApproval {
                            Button("Open System Settings → Login Items") {
                                loginItem.openLoginItemsSettings()
                            }
                            .font(.caption)
                        }
                    }
                }

                if let error = loginItem.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Bars") {
                MenuBarBarsSettingsView(
                    bars: $settingsStore.settings.menuBarBars,
                    allowed: settingsStore.settings.allowedMenuBarSources
                )
                Text("Which quota each bar shows, top to bottom. Drag a quota onto a bar to put it there; dragging one that is already placed swaps the two.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Time remaining") {
                Toggle("Show time remaining in the menu bar", isOn: Binding(
                    get: { settingsStore.settings.menuBarDisplayMode != .iconOnly },
                    set: { settingsStore.settings.menuBarDisplayMode = $0 ? .iconAndText : .iconOnly }
                ))

                // Its own choice rather than "whatever the top bar shows": the
                // most useful deadline is not always one the bars have room for.
                Picker("Count down to", selection: $settingsStore.settings.menuBarCountdownSource) {
                    ForEach(settingsStore.settings.allowedMenuBarSources) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .disabled(settingsStore.settings.menuBarDisplayMode == .iconOnly)

                Text("Time left before the chosen window resets — \"3:44\", or \"6d 18h\" when a reset is more than a day out. Blank while that window is not running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            }

            Section("Highlight") {
                Toggle(
                    "Highlight when it's a good time to spend quota",
                    isOn: $settingsStore.settings.menuBarHighlightWhenReady
                )
                Text("Lights the bars in the menu bar while the session window is inside your reminder lead time and still has usable quota. Works independently of notifications. Switched off, the icon stays plain at all times.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Everything below configures the highlight, so it all goes grey
                // together when the highlight is off — but the switch above must
                // stay live, or there would be no way back on.
                Group {
                    HighlightColorPicker(color: $settingsStore.settings.menuBarHighlightColor)

                    Toggle("Add a glow", isOn: $settingsStore.settings.menuBarHighlightGlow)

                    HighlightPreview(
                        color: settingsStore.settings.menuBarHighlightColor,
                        glow: settingsStore.settings.menuBarHighlightGlow
                    )

                    if !settingsStore.settings.menuBarHighlightColor.isLegibleOnAnyMenuBar {
                        Label(
                            "This colour is hard to make out against a light or a dark menu bar. Menu bar contrast follows your wallpaper, so the icon has to survive both.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        Text("The preview shows the lit icon on a light and a dark menu bar. \"Preview\" lights the real one for eight seconds.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Preview") { usage.previewBurnGlow() }
                            .font(.caption)
                    }
                }
                .disabled(!settingsStore.settings.menuBarHighlightWhenReady)
            }

            Section {
                Toggle("Show projected pace", isOn: $settingsStore.settings.showProjections)
                Text("Under each meter: whether your spending is ahead of or behind an even burn of the window, and when it runs out if you are ahead. The marker on the bar is where an even burn would have left the meter right now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Queue") {
                Toggle("Enable task queue", isOn: $settingsStore.settings.queueEnabled)
                Text("The prompt queue: its section in the menu bar popover, the queue window, the dock badge, and the queue actions on reminder banners. Switching it off leaves Tokenmax a pure quota meter and keeps your saved tasks on disk untouched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Terminal", selection: $settingsStore.settings.terminalApplication) {
                ForEach(AppSettings.terminalOptions, id: \.self) { app in
                    Text(app).tag(app)
                }
            }
            .disabled(!settingsStore.settings.queueEnabled)

            Section {
                LabeledContent("Background refresh") {
                    Text("\(Int(settingsStore.settings.backgroundRefreshSeconds / 60)) min")
                }
                LabeledContent("Mark stale after") {
                    Text("\(Int(settingsStore.settings.staleAfterSeconds / 60)) min")
                }
                Text("Usage requests to Anthropic are rate-limited to one every 3 minutes regardless of these values.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // The registration can be revoked from System Settings while Tokenmax
        // is running, so re-read it whenever the pane comes back into view.
        .onAppear { loginItem.refresh() }
    }
}

/// Preset swatches plus a system colour well.
///
/// The presets are there because they are all known to survive both a light and
/// a dark menu bar; the well is there because a fixed palette cannot match
/// someone's existing menu bar, and refusing the choice would be the wrong kind
/// of protection. The legibility warning next to it covers the gap.
private struct HighlightColorPicker: View {
    @Binding var color: HighlightColor

    var body: some View {
        LabeledContent("Colour") {
            HStack(spacing: 7) {
                ForEach(HighlightColor.presets) { preset in
                    swatch(preset)
                }

                ColorPicker(
                    "Custom highlight colour",
                    selection: Binding(
                        get: { color.color },
                        set: { color = HighlightColor($0) }
                    ),
                    // Alpha is not stored; offering it would silently discard
                    // half of what the user picked.
                    supportsOpacity: false
                )
                .labelsHidden()
            }
        }
    }

    private func swatch(_ preset: HighlightPreset) -> some View {
        let isSelected = preset.color == color

        return Button {
            color = preset.color
        } label: {
            Circle()
                .fill(preset.color.color)
                .frame(width: 16, height: 16)
                .overlay(
                    Circle().strokeBorder(
                        Color.primary.opacity(isSelected ? 0.85 : 0.15),
                        lineWidth: isSelected ? 2 : 1
                    )
                )
        }
        .buttonStyle(.plain)
        .help(preset.name)
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The lit icon, drawn by the real renderer, on both extremes of menu bar.
///
/// Two chips rather than one because the choice being made is a contrast
/// judgement and the user cannot make it against a settings window background —
/// menu bar contrast follows the wallpaper, not the system appearance.
private struct HighlightPreview: View {
    let color: HighlightColor
    let glow: Bool

    var body: some View {
        LabeledContent("Preview") {
            HStack(spacing: 8) {
                chip(background: Color(white: 0.93))
                chip(background: Color(white: 0.14))
            }
        }
    }

    private func chip(background: Color) -> some View {
        Image(nsImage: MenuBarIconRenderer.image(
            // Two bars regardless of the user's layout: this swatch is about
            // whether the *colour* survives a light and a dark menu bar, and a
            // third bar would only make the sample thinner to judge.
            bars: [.init(fraction: 62, isReady: true), .init(fraction: 78, isReady: true)],
            isStale: false,
            highlight: color,
            glow: glow
        ))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}

struct NotificationSettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var usage: ProviderUsageCoordinator
    @EnvironmentObject private var notificationManager: NotificationManager
    @EnvironmentObject private var notifications: NotificationCoordinator

    var body: some View {
        Form {
            Section {
                Toggle("Enable reminders", isOn: Binding(
                    get: { settingsStore.settings.remindersEnabled },
                    set: { enabled in
                        settingsStore.settings.remindersEnabled = enabled
                        // Permission is requested only here — never at launch.
                        if enabled {
                            Task { await notificationManager.requestAuthorization() }
                        }
                    }
                ))

                if notificationManager.authState == .denied {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notifications are disabled for Tokenmax.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Open System Settings → Notifications") {
                            notificationManager.openSystemNotificationSettings()
                        }
                        .font(.caption)
                    }
                }
            }

            if settingsStore.settings.claudeCodeEnabled {
                reminderSection(
                    title: "\(TokenmaxProvider.claudeCode.displayName) session",
                    rule: $settingsStore.settings.sessionReminder,
                    leadOptions: [10, 15, 30, 45, 60],
                    kind: .session,
                    provider: .claudeCode
                )

                reminderSection(
                    title: "\(TokenmaxProvider.claudeCode.displayName) weekly window",
                    rule: $settingsStore.settings.weeklyReminder,
                    leadOptions: [60, 120, 240, 480, 1440],
                    kind: .weekly,
                    provider: .claudeCode
                )
            }

            // Its own rule, not a toggle on Claude's: the two weeks are
            // different lengths of rope, so one threshold cannot fit both.
            // Codex reports no session window, hence no session section.
            //
            // Hidden rather than disabled when the data source is off: there is
            // nothing to remind about, and the rule stays on disk regardless.
            if settingsStore.settings.codexEnabled {
                reminderSection(
                    title: "\(TokenmaxProvider.codex.displayName) weekly window",
                    rule: $settingsStore.settings.codexWeeklyReminder,
                    leadOptions: [60, 120, 240, 480, 1440],
                    kind: .weekly,
                    provider: .codex
                )
            }

            Section("Quiet hours") {
                Toggle("Enable quiet hours", isOn: $settingsStore.settings.quietHours.enabled)
                if settingsStore.settings.quietHours.enabled {
                    timePicker("From", minutes: $settingsStore.settings.quietHours.startMinutes)
                    timePicker("To", minutes: $settingsStore.settings.quietHours.endMinutes)
                }
            }

            Section {
                Toggle("Play sound", isOn: $settingsStore.settings.playSound)
                Toggle("Show badge", isOn: $settingsStore.settings.showBadge)
                Text("If your Mac is asleep when a reminder is due, macOS delivers it on wake rather than at the scheduled time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await notificationManager.refreshAuthState() }
    }

    private func reminderSection(
        title: String,
        rule: Binding<ReminderRule>,
        leadOptions: [Int],
        kind: UsageWindowKind,
        provider: TokenmaxProvider
    ) -> some View {
        Section(title) {
            Toggle("Remind me before reset", isOn: rule.enabled)

            // Shows the effect of every control below it, so changing a setting
            // has visible consequences instead of silent ones.
            if let status = notifications.status(for: provider, kind: kind) {
                HStack(spacing: 5) {
                    Image(systemName: status.isSuppressed ? "bell.slash" : "bell")
                        .font(.caption)
                    Text(status.summary())
                        .font(.caption)
                    Spacer()
                    if case .suppressed(.alreadyFiredForWindow, _) = status {
                        Button("Send Again") {
                            Task { await notifications.rearmCurrentWindow(kind, provider: provider) }
                        }
                        .font(.caption)
                    }
                }
                .foregroundStyle(status.isNoteworthy ? Color.orange : Color.secondary)
            }

            Picker("Lead time", selection: rule.leadTimeMinutes) {
                ForEach(leadOptions, id: \.self) { minutes in
                    Text(leadLabel(minutes)).tag(minutes)
                }
            }
            .disabled(!rule.wrappedValue.enabled)

            Picker("Minimum remaining quota", selection: rule.minimumRemainingPercent) {
                ForEach([5.0, 10.0, 20.0, 30.0, 50.0], id: \.self) { value in
                    Text("\(Int(value))%").tag(value)
                }
            }
            .disabled(!rule.wrappedValue.enabled)

            // Hidden rather than disabled when the queue is off: the stored
            // value is deliberately left alone so it comes back as configured,
            // and the scheduler ignores it in the meantime.
            if settingsStore.settings.queueEnabled {
                Toggle("Only notify when tasks are queued", isOn: rule.onlyWhenTasksQueued)
                    .disabled(!rule.wrappedValue.enabled)
            }
            Toggle("Notify once per window", isOn: rule.notifyOncePerWindow)
                .disabled(!rule.wrappedValue.enabled)
        }
    }

    private func leadLabel(_ minutes: Int) -> String {
        if minutes >= 1440 { return "\(minutes / 1440) day before reset" }
        if minutes >= 60 { return "\(minutes / 60) hours before reset" }
        return "\(minutes) minutes before reset"
    }

    private func timePicker(_ label: String, minutes: Binding<Int>) -> some View {
        DatePicker(
            label,
            selection: Binding(
                get: {
                    Calendar.current.date(
                        bySettingHour: minutes.wrappedValue / 60,
                        minute: minutes.wrappedValue % 60,
                        second: 0,
                        of: Date()
                    ) ?? Date()
                },
                set: { date in
                    let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                    minutes.wrappedValue = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                }
            ),
            displayedComponents: .hourAndMinute
        )
    }
}

struct DataSourceSettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var usage: ProviderUsageCoordinator
    @EnvironmentObject private var modelCatalog: ModelCatalogStore

    @State private var installError: String?

    /// Says what the picker is actually working from — a fetched list, a stale
    /// cache, or the built-in fallback — so a failed fetch is visible rather
    /// than just looking like an oddly short list.
    private var catalogSummary: String {
        if modelCatalog.isRefreshing { return "Refreshing…" }
        if let error = modelCatalog.lastError { return error }
        guard !modelCatalog.catalog.isEmpty else { return "Not fetched yet — using built-in aliases" }
        let age = RelativeTime.short(Date().timeIntervalSince(modelCatalog.catalog.fetchedAt))
        return "\(modelCatalog.catalog.models.count) models · updated \(age) ago"
    }

    /// True when this is the only source still on, so its toggle can be locked.
    /// The app is a quota meter; with nothing enabled the menu bar item renders
    /// an empty label, which is invisible *and* unclickable — leaving no way
    /// back to this screen.
    private func isLastEnabled(_ provider: TokenmaxProvider) -> Bool {
        settingsStore.settings.isEnabled(provider) && settingsStore.settings.enabledProviders.count == 1
    }

    var body: some View {
        Form {
            Section("Claude Code") {
                Toggle("Monitor Claude Code usage", isOn: $settingsStore.settings.claudeCodeEnabled)
                    .disabled(isLastEnabled(.claudeCode))

                if isLastEnabled(.claudeCode) {
                    Text("At least one data source has to stay on — Tokenmax has nothing to show otherwise.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if settingsStore.settings.claudeCodeEnabled {
                    LabeledContent("Endpoint") {
                        Text("api.anthropic.com/api/oauth/usage")
                            .font(.system(size: 10, design: .monospaced))
                    }
                    LabeledContent("Credentials") {
                        Text("macOS Keychain")
                    }
                    Text("Reads the OAuth token Claude Code already stores in your login keychain. Nothing is sent anywhere except Anthropic, and no credentials are written to disk by Tokenmax.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if settingsStore.settings.claudeCodeEnabled {
                Section("Fallback — Claude Code status line") {
                    Toggle("Install status line shim", isOn: Binding(
                        get: { settingsStore.settings.statuslineShimInstalled },
                        set: { toggleShim($0) }
                    ))
                    Text("Writes a small script and sets \"statusLine\" in ~/.claude/settings.json, wrapping any status line you already use. This is the officially documented source, but it only updates while a Claude Code session is running.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let installError {
                        Text(installError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            if settingsStore.settings.claudeCodeEnabled {
                Section("Available models") {
                    LabeledContent("Catalog") {
                        Text(catalogSummary)
                            .font(.caption)
                            .foregroundStyle(modelCatalog.lastError == nil ? Color.secondary : Color.orange)
                    }
                    HStack {
                        Button("Refresh models") {
                            Task { await modelCatalog.refresh(force: true) }
                        }
                        .disabled(modelCatalog.isRefreshing)
                        Spacer()
                    }
                    .font(.caption)
                    Text("Fetched from api.anthropic.com/v1/models with the same keychain token as your usage, so a newly released model shows up in the task editor without updating Tokenmax. Refreshed daily; the last list is cached and used offline. If the fetch fails, the built-in aliases still work.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Codex") {
                Toggle("Monitor Codex usage", isOn: $settingsStore.settings.codexEnabled)
                    .disabled(isLastEnabled(.codex))

                if isLastEnabled(.codex) {
                    Text("At least one data source has to stay on — Tokenmax has nothing to show otherwise.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Reads your ChatGPT quota through the Codex app server. Switching this off stops the polling, hides Codex everywhere in the app, and leaves its queued tasks in place without running them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // One section per enabled provider, so a disabled source cannot
            // leave a frozen last-known reading on screen looking current.
            ForEach(settingsStore.settings.enabledProviders) { provider in
                Section("\(provider.displayName) — current windows") {
                    if let snapshot = usage.snapshot(for: provider), !snapshot.windows.isEmpty {
                        ForEach(snapshot.windows) { window in
                            LabeledContent(window.label) {
                                Text("\(window.source.displayName) · \(window.confidence.rawValue)")
                                    .font(.caption)
                            }
                        }
                    } else {
                        Text("No usage data yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            settingsStore.settings.statuslineShimInstalled = StatuslineShimInstaller.isInstalled
            modelCatalog.refreshIfStale()
        }
    }

    private func toggleShim(_ install: Bool) {
        installError = nil
        do {
            if install {
                try StatuslineShimInstaller.install()
            } else {
                try StatuslineShimInstaller.uninstall()
            }
            settingsStore.settings.statuslineShimInstalled = StatuslineShimInstaller.isInstalled
        } catch {
            installError = error.localizedDescription
            settingsStore.settings.statuslineShimInstalled = StatuslineShimInstaller.isInstalled
        }
    }
}
