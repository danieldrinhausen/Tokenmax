import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            JSONStore.save(settings, to: FileLocations.settingsFile)
            // Mirrored on every save so the Claude provider — which fetches
            // off the main actor and cannot read this store — always sees the
            // current choice. See `ClaudeDataSourceFlag`.
            ClaudeDataSourceFlag.shared.set(settings.claudeDataSource)
        }
    }

    init() {
        settings = JSONStore.load(AppSettings.self, from: FileLocations.settingsFile) ?? AppSettings()
        ClaudeDataSourceFlag.shared.set(settings.claudeDataSource)
    }
}
