import AppKit
import Foundation
import ServiceManagement

/// "Start at login", backed by `SMAppService.mainApp`.
///
/// Deliberately **not** mirrored into `AppSettings`. The registration lives in
/// the system, and the user can revoke it from System Settings → General →
/// Login Items without the app ever running. A cached bool in `settings.json`
/// would drift out of sync with that and start lying to the user, so
/// `SMAppService.status` is treated as the only source of truth and the toggle
/// simply reflects it.
@MainActor
final class LoginItemService: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var errorMessage: String?

    private let service = SMAppService.mainApp

    init() {
        refresh()
    }

    var isEnabled: Bool { status == .enabled }

    func refresh() {
        status = service.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            errorMessage = nil
            Log.shared.write("login item \(enabled ? "registered" : "unregistered")")
        } catch {
            // Most commonly this is an app running from DerivedData rather than
            // /Applications, which the system refuses to register.
            errorMessage = error.localizedDescription
            Log.shared.write("login item change to \(enabled) failed: \(error)")
        }
        refresh()
    }

    /// Login Items lives in General, not in a privacy pane like the others.
    func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    /// User-facing explanation of a non-`.enabled` state, or `nil` when there is
    /// nothing to explain.
    var statusExplanation: String? {
        switch status {
        case .enabled, .notRegistered:
            nil
        case .requiresApproval:
            "Approval is needed in System Settings → General → Login Items."
        case .notFound:
            "Tokenmax has to be in /Applications to start at login."
        @unknown default:
            nil
        }
    }

    var needsApproval: Bool { status == .requiresApproval }
}
