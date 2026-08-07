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
}
