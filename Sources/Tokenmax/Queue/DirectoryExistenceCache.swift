import Foundation

/// Short-lived answers to "does this working directory still exist?".
///
/// The queue window redraws once a second — `UsageRefreshCoordinator.tick`
/// drives every countdown on screen — and each card wants to know whether its
/// directory is still there. Asked directly, that is one `stat` per card per
/// second for as long as the window is open.
///
/// A few seconds of staleness is the right trade *for the card*, which is
/// telling the user something about a directory they are not currently deleting.
/// It is the wrong trade for anything that decides whether to spend quota, so
/// the runner and the auto-run gates keep calling
/// `TokenmaxTask.workingDirectoryExists` directly and always see live truth.
@MainActor
final class DirectoryExistenceCache {
    /// Long enough to collapse a burst of redraws, short enough that deleting a
    /// directory shows up on the card while the user is still looking at it.
    static let lifetime: TimeInterval = 5

    private var entries: [String: (exists: Bool, readAt: Date)] = [:]

    func exists(_ task: TokenmaxTask, now: Date = Date()) -> Bool {
        guard let path = task.workingDirectory, !path.isEmpty else { return false }

        if let entry = entries[path], now.timeIntervalSince(entry.readAt) < Self.lifetime {
            return entry.exists
        }

        let value = task.workingDirectoryExists
        entries[path] = (value, now)
        return value
    }

    /// Drops every cached answer, so the next read hits the filesystem. Called
    /// when the user does something that implies they expect a fresh look —
    /// editing a task, or refreshing the window.
    func invalidate() {
        entries.removeAll()
    }
}
