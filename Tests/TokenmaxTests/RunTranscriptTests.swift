import Foundation
import Testing

@testable import Tokenmax

@Suite("Run transcript")
struct RunTranscriptTests {
    /// Shaped after a real `--output-format stream-json` capture, including the
    /// noise that has to be ignored: thinking blocks, token-counter events, and
    /// a result envelope with far more fields than are read.
    private let log = """
    {"type":"system","subtype":"init","session_id":"abc"}
    {"type":"system","subtype":"thinking_tokens","estimated_tokens":24}
    {"type":"assistant","message":{"content":[{"type":"thinking","thinking":"Let me plan this out carefully"}]}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"I'll look at the parser first."}]}}
    {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Grep","input":{"pattern":"func parse"}}]}}
    {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/project/src/math.swift"}}]}}
    {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/tmp/project/src/math.swift"}}]}}
    {"type":"result","subtype":"success","is_error":false,"result":"Added a doc comment to `add`.","total_cost_usd":0.0201,"num_turns":4,"permission_denials":[]}
    """

    @Test("The final answer is pulled out of the stream")
    func extractsResult() {
        let transcript = RunTranscript.parse(log: log)
        #expect(transcript.result == "Added a doc comment to `add`.")
        #expect(transcript.costUSD == 0.0201)
        #expect(transcript.turns == 4)
        #expect(!transcript.isError)
    }

    @Test("Thinking blocks and counter events are dropped")
    func ignoresNoise() {
        // Thinking is long, is not the answer, and burying the result under it
        // is exactly the problem this view exists to fix.
        let transcript = RunTranscript.parse(log: log)
        let texts = transcript.entries.compactMap { entry -> String? in
            if case let .text(value) = entry { return value }
            return nil
        }
        #expect(texts == ["I'll look at the parser first."])
    }

    @Test("Tool calls are summarised by what they acted on")
    func summarisesTools() {
        let transcript = RunTranscript.parse(log: log)
        let tools = transcript.entries.compactMap { entry -> (String, String?)? in
            if case let .tool(name, detail) = entry { return (name, detail) }
            return nil
        }

        #expect(tools.count == 3)
        #expect(tools[0].0 == "Grep")
        #expect(tools[0].1 == "func parse")
        // Paths are shortened: every entry shares a working directory, so the
        // prefix is noise.
        #expect(tools[1] == ("Read", "math.swift"))
        #expect(tools[2] == ("Edit", "math.swift"))
    }

    @Test("Denied tools are captured")
    func capturesDenials() {
        // The usual explanation for a run that looks like it under-delivered.
        let denied = """
        {"type":"result","subtype":"success","is_error":false,"result":"Could not run the command.",\
        "permission_denials":[{"tool_name":"Bash","tool_input":{"command":"git status"}}]}
        """
        let transcript = RunTranscript.parse(log: denied)
        #expect(transcript.deniedTools == ["Bash"])
    }

    @Test("A truncated or malformed log degrades rather than throwing")
    func survivesMalformedInput() {
        // The log is bounded, so a long run really can be cut mid-line.
        let broken = """
        {"type":"assistant","message":{"content":[{"type":"text","text":"Partial work"}]}}
        not json at all
        {"type":"assistant","message":{"conte
        """
        let transcript = RunTranscript.parse(log: broken)
        #expect(transcript.entries.count == 1)
        #expect(transcript.result == nil)
    }

    @Test("An empty log is empty, not a crash")
    func handlesEmptyLog() {
        #expect(RunTranscript.parse(log: "").isEmpty)
        #expect(RunTranscript.parse(logURL: URL(fileURLWithPath: "/nope/missing.log")).isEmpty)
    }

    @Test("Tool detail picks the right field per tool")
    func toolDetailFields() {
        #expect(RunTranscript.detail(for: "Bash", input: ["command": "swift build"]) == "swift build")
        #expect(RunTranscript.detail(for: "Glob", input: ["pattern": "**/*.swift"]) == "**/*.swift")
        #expect(RunTranscript.detail(for: "Write", input: ["file_path": "/a/b/c.txt"]) == "c.txt")
        #expect(RunTranscript.detail(for: "Unknown", input: ["x": "y"]) == nil)
        #expect(RunTranscript.detail(for: "Read", input: nil) == nil)
    }

    @Test("Markdown export leads with the result")
    func markdownExport() throws {
        let transcript = RunTranscript.parse(log: log)
        var record = TaskRunRecord(
            taskID: UUID(),
            taskTitle: "Document the parser",
            windowID: "w",
            trigger: .manual,
            model: "sonnet",
            workingDirectory: "/tmp/project",
            status: .completed
        )
        record.finishedAt = record.startedAt.addingTimeInterval(42)

        let markdown = transcript.markdown(title: record.taskTitle, record: record)
        #expect(markdown.hasPrefix("# Document the parser"))
        #expect(markdown.contains("## Result"))
        #expect(markdown.contains("Added a doc comment"))
        #expect(markdown.contains("## Activity"))
        #expect(markdown.contains("- Edit — `math.swift`"))
        #expect(markdown.contains("Cost: $0.0201"))

        // The result must come before the activity list: it is what the reader
        // opened the file for.
        let resultIndex = try #require(markdown.range(of: "## Result")).lowerBound
        let activityIndex = try #require(markdown.range(of: "## Activity")).lowerBound
        #expect(resultIndex < activityIndex)
    }

    @Test("A thread exports every turn, with what was asked")
    func markdownThread() throws {
        func record(_ reply: String?) -> TaskRunRecord {
            var record = TaskRunRecord(
                taskID: UUID(),
                taskTitle: "Document the parser",
                windowID: "w",
                trigger: .manual,
                model: "sonnet",
                workingDirectory: "/tmp/project",
                status: .completed
            )
            record.replyText = reply
            record.finishedAt = record.startedAt.addingTimeInterval(10)
            return record
        }

        let turns = [
            RunTurn(record: record(nil), transcript: RunTranscript.parse(log: log)),
            RunTurn(
                record: record("Also add a test"),
                transcript: RunTranscript.parse(
                    log: "{\"type\":\"result\",\"result\":\"Added `testAdd`.\"}"
                )
            ),
        ]

        let markdown = RunTranscript.markdown(title: "Document the parser", turns: turns)
        #expect(markdown.hasPrefix("# Document the parser"))
        #expect(markdown.contains("## Turn 1"))
        #expect(markdown.contains("## Turn 2"))
        #expect(markdown.contains("**You asked:** Also add a test"))
        #expect(markdown.contains("Added a doc comment"))
        #expect(markdown.contains("Added `testAdd`."))
        // Turn sections nest under their turn heading rather than competing
        // with it.
        #expect(markdown.contains("### Result"))

        let firstIndex = try #require(markdown.range(of: "## Turn 1")).lowerBound
        let secondIndex = try #require(markdown.range(of: "## Turn 2")).lowerBound
        #expect(firstIndex < secondIndex)
    }

    @Test("A single-turn thread renders as a plain run")
    func markdownSingleTurn() {
        // The common case should not gain headings it has no use for.
        let record = TaskRunRecord(
            taskID: UUID(),
            taskTitle: "One shot",
            windowID: "w",
            trigger: .manual,
            model: "sonnet",
            workingDirectory: "/tmp/project",
            status: .completed
        )
        let turns = [RunTurn(record: record, transcript: RunTranscript.parse(log: log))]
        let markdown = RunTranscript.markdown(title: "One shot", turns: turns)

        #expect(!markdown.contains("## Turn 1"))
        #expect(markdown.contains("## Result"))
    }

    @Test("Export omits sections it has nothing for")
    func markdownOmitsEmptySections() {
        let transcript = RunTranscript.parse(log: "{\"type\":\"result\",\"result\":\"Just a note.\"}")
        let markdown = transcript.markdown(title: "Quick one", record: nil)
        #expect(markdown.contains("Just a note."))
        #expect(!markdown.contains("## Activity"))
        #expect(!markdown.contains("## Blocked"))
    }
}
