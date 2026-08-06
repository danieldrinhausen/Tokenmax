import SwiftUI

/// Which build is running, and whether there is a newer one.
///
/// Notify only — see `UpdateCheckCoordinator` for why nothing here installs
/// anything. The button opens the release page; the download and the drag to
/// Applications stay the user's.
struct AboutSettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var updates: UpdateCheckCoordinator

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: AppInfo.version)
                LabeledContent("Build", value: AppInfo.build)
                LabeledContent("Requires", value: "macOS 14 or later")
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $settingsStore.settings.checkForUpdates)
                Text("Asks GitHub once a day whether a newer release has been published. Tokenmax never installs anything by itself — it only tells you, and links to the release. Nothing is sent: this is an unauthenticated request for the public release list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button("Check Now") {
                        Task { await updates.check(force: true) }
                    }
                    .disabled(updates.state == .checking)

                    status
                }

                if let checked = updates.lastCheckedAt {
                    Text("Last checked \(RelativeTime.short(Date().timeIntervalSince(checked))) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // The suppression is named rather than left as silence — "why
                // has it not noticed the new version?" has an answer on screen.
                if let suppression = updates.lastSuppression, suppression != .notNewer {
                    Text(suppression.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Link("Releases on GitHub", destination: URL(string: "https://github.com/danieldrinhausen/Tokenmax/releases")!)
                Link("Report an issue", destination: URL(string: "https://github.com/danieldrinhausen/Tokenmax/issues")!)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var status: some View {
        switch updates.state {
        case .idle:
            EmptyView()
        case .checking:
            Text("Checking…").font(.caption).foregroundStyle(.secondary)
        case .upToDate:
            Label("Up to date", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .available(version, page):
            Link(destination: page) {
                Label("\(version.description) is available", systemImage: "arrow.down.circle")
                    .font(.caption)
            }
        // Orange, not red, and never "up to date": a check that could not
        // complete has confirmed nothing.
        case let .unavailable(message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
