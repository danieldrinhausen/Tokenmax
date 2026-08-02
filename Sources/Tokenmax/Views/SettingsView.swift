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
    @EnvironmentObject private var usage: UsageRefreshCoordinator

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

            Section {
                Toggle("Show time remaining in the menu bar", isOn: Binding(
                    get: { settingsStore.settings.menuBarDisplayMode != .iconOnly },
                    set: { settingsStore.settings.menuBarDisplayMode = $0 ? .iconAndText : .iconOnly }
                ))
                Text("Time left in the current session window, beside the bars — \"3:44\", or just the minutes under an hour. Blank while no window is running.")
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
            session: 62,
            weekly: 78,
            isStale: false,
            isReady: true,
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

            reminderSection(
                title: "Claude session (5-hour)",
                rule: $settingsStore.settings.sessionReminder,
                leadOptions: [10, 15, 30, 45, 60],
                kind: .session
            )

            reminderSection(
                title: "Weekly window",
                rule: $settingsStore.settings.weeklyReminder,
                leadOptions: [60, 120, 240, 480, 1440],
                kind: .weekly
            )

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
        kind: UsageWindowKind
    ) -> some View {
        Section(title) {
            Toggle("Remind me before reset", isOn: rule.enabled)

            // Shows the effect of every control below it, so changing a setting
            // has visible consequences instead of silent ones.
            if let status = notifications.statuses[kind] {
                HStack(spacing: 5) {
                    Image(systemName: status.isSuppressed ? "bell.slash" : "bell")
                        .font(.caption)
                    Text(status.summary())
                        .font(.caption)
                    Spacer()
                    if case .suppressed(.alreadyFiredForWindow, _) = status {
                        Button("Send Again") {
                            Task { await notifications.rearmCurrentWindow(kind) }
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
    @EnvironmentObject private var usage: UsageRefreshCoordinator

    @State private var installError: String?

    var body: some View {
        Form {
            Section("Primary — Claude account") {
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

            Section("Current windows") {
                if let snapshot = usage.state.snapshot, !snapshot.windows.isEmpty {
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
        .formStyle(.grouped)
        .onAppear {
            settingsStore.settings.statuslineShimInstalled = StatuslineShimInstaller.isInstalled
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
