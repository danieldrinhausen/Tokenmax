import Foundation

/// Asks macOS for access to the folders queued tasks live in, at launch, while
/// somebody is there to answer.
///
/// The problem this exists to solve is one of timing rather than permission.
/// Documents, Desktop, Downloads and iCloud Drive are gated by TCC, and the
/// first attempt to read one raises a consent dialog that **blocks the caller
/// until it is answered**. An unattended run is precisely the case where nobody
/// will answer it, so the run blocks until its runtime limit kills it — no
/// output, no transcript, and a paused queue.
///
/// Asking at launch moves the dialog to the one moment it is reasonable: the
/// user just started the app and is looking at the screen. By the time the
/// scheduler wants an answer, macOS already has one cached.
///
/// It also has to be *re-*asked more often than one would expect. TCC grants are
/// keyed to the code signature, and an ad-hoc-signed build has a new one after
/// every rebuild, so a developer running `make install` loses the grant each
/// time. That is a signing problem rather than something this can fix — see
/// README → Building a release — but it is why this runs on every launch rather
/// than once ever.
enum WorkingDirectoryAccess {
    /// Probes each distinct working directory among `tasks`.
    ///
    /// Off the main thread, always: every probe can block on a dialog, and a
    /// user with three tasks in three protected folders would otherwise freeze
    /// the app for as long as it takes to answer all three.
    ///
    /// Only directories that exist are probed. A missing one is a different
    /// problem with its own message, and asking macOS about it would raise a
    /// permission dialog for a path the user has not typed correctly yet.
    static func requestAccess(for tasks: [TokenmaxTask]) {
        let directories = distinctExistingDirectories(in: tasks)
        guard !directories.isEmpty else { return }

        Task.detached(priority: .utility) {
            for task in directories {
                let readable = task.workingDirectoryReadable
                Log.shared.write(
                    "access: \(readable ? "ok" : "DENIED") — \(task.workingDirectory ?? "?")"
                )
            }
        }
    }

    /// One representative task per directory, so three tasks in the same
    /// checkout raise one dialog rather than three.
    static func distinctExistingDirectories(in tasks: [TokenmaxTask]) -> [TokenmaxTask] {
        var seen = Set<String>()
        return tasks.filter { task in
            guard task.status == .ready || task.status == .needsAttention,
                  let path = task.expandedWorkingDirectory?.path,
                  task.workingDirectoryExists,
                  !seen.contains(path)
            else { return false }
            seen.insert(path)
            return true
        }
    }
}
