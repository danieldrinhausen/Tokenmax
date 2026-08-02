import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            JSONStore.save(settings, to: FileLocations.settingsFile)
        }
    }

    init() {
        settings = JSONStore.load(AppSettings.self, from: FileLocations.settingsFile) ?? AppSettings()
    }
}
