import Foundation
import UserNotifications

/// The auto-runner's own banners.
///
/// Deliberately a separate category from the quota reminder. They answer
/// different questions — "quota is about to expire" versus "Tokenmax is about to
/// run your code" — carry different actions, and a user who silences one has not
/// asked to silence the other.
@MainActor
final class AutoRunNotifier {
    static let categoryIdentifier = "TOKENMAX_QUEUE_AUTORUN"

    enum Action {
        static let startNow = "TOKENMAX_AUTORUN_START"
        static let cancel = "TOKENMAX_AUTORUN_CANCEL"
        static let viewOutput = "TOKENMAX_AUTORUN_VIEW_OUTPUT"
        static let openQueue = "TOKENMAX_AUTORUN_OPEN_QUEUE"
    }

    private var settings: QueueAutoRunSettings = .init()

    func apply(_ settings: QueueAutoRunSettings) {
        self.settings = settings
    }

    /// A task has become eligible. `startingInSeconds` is non-nil in automatic
    /// mode, where the countdown is already running and the banner is a chance
    /// to stop it rather than a request for permission.
    func eligible(task: TokenmaxTask, startingInSeconds: Int?, autoStart: Bool) {
        let body: String
        if let startingInSeconds {
            body = "\(task.title) starts in \(startingInSeconds) seconds."
        } else {
            let estimate = task.estimatedMinutes.map { " · ~\($0) min" } ?? ""
            body = "\(task.title)\(estimate)"
        }

        post(
            title: autoStart ? "Tokenmax is starting a queued task" : "Tokenmax found an eligible task",
            body: body,
            identifier: "autorun-eligible-\(task.id.uuidString)"
        )
    }

    func started(task: TokenmaxTask) {
        guard settings.notifyOnStart else { return }
        let project = task.projectName.map { " · \($0)" } ?? ""
        post(
            title: "Tokenmax started a queued task",
            body: "\(task.title)\(project)",
            identifier: "autorun-started-\(task.id.uuidString)"
        )
    }

    func completed(record: TaskRunRecord) {
        guard settings.notifyOnCompletion else { return }
        let cost = record.costUSD.map { String(format: " · $%.3f", $0) } ?? ""
        post(
            title: "Tokenmax completed a queued task",
            body: "\(record.taskTitle) finished \(record.status.displayName.lowercased())\(cost).",
            identifier: "autorun-done-\(record.id.uuidString)"
        )
    }

    /// Not gated on a setting. A queue that has silently stopped is the state
    /// most likely to be mistaken for a broken app, and the user cannot ask for
    /// it back if they never learn it happened.
    func failed(record: TaskRunRecord) {
        post(
            title: title(for: record),
            body: "\(record.taskTitle): \(record.errorMessage ?? "the task did not finish.")",
            identifier: "autorun-failed-\(record.id.uuidString)"
        )
    }

    /// A rejected command line gets its own title because the user's next move
    /// is different: nothing about the task or the queue needs looking at, and
    /// resuming would only reproduce the failure. Everything else keeps the
    /// wording it had.
    private func title(for record: TaskRunRecord) -> String {
        if record.status == .incompatibleCLI {
            return "Tokenmax needs updating for this CLI"
        }
        return settings.pauseAfterFailure ? "Tokenmax paused the queue" : "A queued task failed"
    }

    private func post(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.categoryIdentifier
        NotificationIcon.attach(to: content)

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        Task {
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                Log.shared.write("autorun notify: failed — \(error.localizedDescription)")
            }
        }
    }
}

extension Notification.Name {
    static let tokenmaxAutoRunCancel = Notification.Name("com.tokenmax.autoRunCancel")
    static let tokenmaxAutoRunStartNow = Notification.Name("com.tokenmax.autoRunStartNow")
    static let tokenmaxAutoRunViewOutput = Notification.Name("com.tokenmax.autoRunViewOutput")
}
