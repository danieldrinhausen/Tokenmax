import Testing

@testable import Tokenmax

@MainActor
@Suite("Overlapping notification syncs coalesce")
struct CoalescingRunnerTests {
    @Test("A request that arrives mid-run triggers exactly one more pass")
    func requestDuringRunRunsAgain() async {
        let runner = CoalescingRunner()
        var passes = 0

        await runner.run {
            passes += 1
            if passes == 1 {
                // Two triggers while the first pass is awaiting still mean one rerun.
                await runner.run { passes += 100 }
                await runner.run { passes += 100 }
            }
        }

        #expect(passes == 2)
    }

    @Test("Nothing reruns when nothing was requested during the pass")
    func quietRunRunsOnce() async {
        let runner = CoalescingRunner()
        var passes = 0
        await runner.run { passes += 1 }
        #expect(passes == 1)
    }

    @Test("A run after the previous one finished starts normally")
    func sequentialRunsBothRun() async {
        let runner = CoalescingRunner()
        var passes = 0
        await runner.run { passes += 1 }
        await runner.run { passes += 1 }
        #expect(passes == 2)
    }

    @Test("A caller that arrives mid-run never overlaps the running pass")
    func neverOverlaps() async {
        let runner = CoalescingRunner()
        var active = 0
        var maxActive = 0
        var passes = 0

        await runner.run {
            passes += 1
            active += 1
            maxActive = max(maxActive, active)
            if passes == 1 { await runner.run { active += 100 } }
            active -= 1
        }

        #expect(maxActive == 1)
        #expect(passes == 2)
    }
}
