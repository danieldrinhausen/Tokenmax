import Foundation
import Testing

@testable import Tokenmax

/// `TaskStore` writes to `TOKENMAX_SUPPORT_DIR`, which the test scheme points
/// at /tmp — no real queue is touched.
@Suite("Task store")
@MainActor
struct TaskStoreTests {
    private func scheduledTask(at start: Date) -> TokenmaxTask {
        var task = TokenmaxTask(
            title: "Codereview",
            prompt: "Review it.",
            workingDirectory: NSTemporaryDirectory(),
            executionMode: .automatic
        )
        task.estimatedMinutes = 15
        task.scheduledStart = start
        return task
    }

    /// Found the hard way: duplicating a task dated a few minutes ago produced
    /// a copy that was immediately due — inside the grace period — and it
    /// started a run seconds after the click, next to the burn window's own
    /// runs. From the queue it looked as though the schedule was being ignored
    /// and the ordinary automation had swept the task up.
    ///
    /// An appointment is one instruction for one task at one moment. It does
    /// not survive a copy, exactly like `startedAt` and `completedAt`.
    @Test("Duplicating a scheduled task does not copy its appointment")
    func duplicateDropsTheAppointment() {
        let store = TaskStore()
        let original = scheduledTask(at: Date().addingTimeInterval(-120))
        store.add(original)

        store.duplicate(original)

        let copy = store.tasks.first { $0.title == "Codereview copy" }
        #expect(copy != nil)
        #expect(copy?.scheduledStart == nil)
        // Everything that made it worth duplicating is still there.
        #expect(copy?.prompt == original.prompt)
        #expect(copy?.executionMode == .automatic)
        #expect(copy?.estimatedMinutes == 15)
        // The original keeps its date — the copy is what changed.
        #expect(store.tasks.first { $0.id == original.id }?.scheduledStart != nil)

        store.delete(original)
        if let copy { store.delete(copy) }
    }

    /// Found by review: the editor saved its whole copy back, so a task the
    /// runner started while the sheet was open went back to `ready` with its
    /// appointment restored — due again, and run a second time on Save.
    @Test("Saving the editor does not undo a run that started while it was open")
    func editorSaveKeepsTheQueueLifecycle() {
        let opened = scheduledTask(at: Date().addingTimeInterval(-60))

        // What the runner did in the meantime: consumed the appointment,
        // started the task, and a drag moved it.
        var current = opened
        current.scheduledStart = nil
        current.status = .running
        current.startedAt = Date()
        current.sortIndex = 7

        var edited = opened
        edited.title = "Codereview, thoroughly"
        edited.prompt = "Review all of it."

        let merged = TaskStore.merging(edited, openedFrom: opened, onto: current)

        #expect(merged.status == .running)
        #expect(merged.startedAt == current.startedAt)
        #expect(merged.sortIndex == 7)
        #expect(merged.scheduledStart == nil)
        // What the user actually typed still lands.
        #expect(merged.title == "Codereview, thoroughly")
        #expect(merged.prompt == "Review all of it.")
    }

    @Test("An appointment the user changed in the editor is saved over the store's value")
    func editorSaveKeepsAChangedAppointment() {
        let opened = scheduledTask(at: Date().addingTimeInterval(3600))
        var current = opened
        current.scheduledStart = nil

        var edited = opened
        let rescheduled = Date().addingTimeInterval(7200)
        edited.scheduledStart = rescheduled

        let merged = TaskStore.merging(edited, openedFrom: opened, onto: current)
        #expect(merged.scheduledStart == rescheduled)
    }
}
