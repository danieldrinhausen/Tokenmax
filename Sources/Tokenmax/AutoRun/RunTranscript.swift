import Foundation

/// A readable account of what a run actually did, reconstructed from its log.
///
/// Derived on demand rather than written as a second file during the run. That
/// keeps one source of truth, works for a run that was interrupted before it
/// could summarise itself, and means the rendering can be improved later
/// without re-running anything.
struct RunTranscript: Sendable, Equatable {
    /// Deliberately not `Identifiable`: a run can legitimately read the same
    /// file twice, so any identity derived from the content would collide.
    /// Callers index by position instead.
    enum Entry: Sendable, Equatable {
        /// Something the model said along the way.
        case text(String)
        /// A tool call, with a short description of what it acted on.
        case tool(name: String, detail: String?)
    }

    var entries: [Entry] = []
    /// The model's final answer — the thing the user actually asked for.
    var result: String?
    var costUSD: Double?
    var turns: Int?
    var isError = false
    /// Tools the run asked for and was refused. Worth surfacing: a task that
    /// looks like it under-delivered has usually hit one of these.
    var deniedTools: [String] = []

    var isEmpty: Bool { entries.isEmpty && result == nil }

    // MARK: - Parsing

    static func parse(logURL: URL) -> RunTranscript {
        guard let data = try? Data(contentsOf: logURL),
              let text = String(data: data, encoding: .utf8)
        else { return RunTranscript() }
        return parse(log: text)
    }

    static func parse(log: String) -> RunTranscript {
        var transcript = RunTranscript()
        var jsonLines = 0

        for line in log.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(line)
            guard let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = root["type"] as? String
            else { continue }

            jsonLines += 1

            switch type {
            case "assistant":
                transcript.appendAssistant(root)
            case "result":
                transcript.applyResult(root)
            default:
                continue
            }
        }

        // A log full of well-formed events that yielded nothing to show means
        // the stream schema moved: the run itself succeeded, so nothing else
        // reports a problem and the output view is simply blank. This is the
        // quietest of the upstream couplings, and the only place it can
        // announce itself is here.
        if jsonLines > 0, transcript.isEmpty {
            Log.shared.write("transcript: \(jsonLines) events parsed but none recognised — stream-json schema may have changed")
        }

        return transcript
    }

    private mutating func appendAssistant(_ root: [String: Any]) {
        guard let message = root["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return }

        for block in content {
            switch block["type"] as? String {
            case "text":
                guard let text = (block["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
                else { continue }
                entries.append(.text(text))

            case "tool_use":
                guard let name = block["name"] as? String else { continue }
                entries.append(.tool(name: name, detail: Self.detail(for: name, input: block["input"])))

            // Thinking blocks are deliberately dropped. They are long, they are
            // not the answer, and including them buries the part the user came
            // to read.
            default:
                continue
            }
        }
    }

    private mutating func applyResult(_ root: [String: Any]) {
        result = (root["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        costUSD = root["total_cost_usd"] as? Double
        turns = root["num_turns"] as? Int
        isError = root["is_error"] as? Bool ?? false

        if let denials = root["permission_denials"] as? [[String: Any]] {
            deniedTools = denials.compactMap { $0["tool_name"] as? String }
        }
    }

    /// The most useful single field from a tool's input — the file it touched,
    /// the pattern it searched for — so the activity list reads as a summary
    /// rather than a list of bare verbs.
    static func detail(for tool: String, input: Any?) -> String? {
        guard let input = input as? [String: Any] else { return nil }

        let key: String? = switch tool {
        case "Read", "Edit", "Write", "NotebookEdit": "file_path"
        case "Grep", "Glob": "pattern"
        case "Bash": "command"
        case "WebFetch": "url"
        case "Task": "description"
        default: nil
        }

        guard let key, let value = input[key] as? String else { return nil }

        // Absolute paths are mostly noise in a list where every entry shares
        // the same working directory.
        let trimmed = key == "file_path" ? (value as NSString).lastPathComponent : value
        return String(trimmed.prefix(120))
    }

    // MARK: - Export

    /// A Markdown rendering, for saving or pasting elsewhere.
    func markdown(title: String, record: TaskRunRecord?) -> String {
        (["# \(title)", ""] + body(depth: 2, record: record)).joined(separator: "\n")
    }

    /// A whole conversation, one section per turn.
    ///
    /// Falls through to the single-run rendering when there is only one turn, so
    /// the common case does not gain headings it has no use for.
    static func markdown(title: String, turns: [RunTurn]) -> String {
        guard let first = turns.first else { return "# \(title)" }
        guard turns.count > 1 else {
            return first.transcript.markdown(title: title, record: first.record)
        }

        var lines: [String] = ["# \(title)", ""]
        for (index, turn) in turns.enumerated() {
            lines.append("## Turn \(index + 1)")
            lines.append("")
            if let reply = turn.record.replyText, !reply.isEmpty {
                lines.append("**You asked:** \(reply)")
                lines.append("")
            }
            lines.append(contentsOf: turn.transcript.body(depth: 3, record: turn.record))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Everything below the document title. `depth` is the heading level for
    /// section titles, so the same rendering serves a standalone run and a turn
    /// nested inside a thread.
    private func body(depth: Int, record: TaskRunRecord?) -> [String] {
        let heading = String(repeating: "#", count: depth)
        var lines: [String] = []

        if let record {
            var meta = [record.startedAt.formatted(date: .abbreviated, time: .shortened)]
            meta.append("model `\(record.model)`")
            if let effort = record.effort, !effort.isEmpty { meta.append("effort `\(effort)`") }
            if !record.workingDirectory.isEmpty { meta.append("`\(record.workingDirectory)`") }
            lines.append(meta.joined(separator: " · "))
            lines.append("")
        }

        if let result, !result.isEmpty {
            lines.append("\(heading) Result")
            lines.append("")
            lines.append(result)
            lines.append("")
        }

        let tools = entries.compactMap { entry -> String? in
            if case let .tool(name, detail) = entry {
                return detail.map { "- \(name) — `\($0)`" } ?? "- \(name)"
            }
            return nil
        }
        if !tools.isEmpty {
            lines.append("\(heading) Activity")
            lines.append("")
            lines.append(contentsOf: tools)
            lines.append("")
        }

        if !deniedTools.isEmpty {
            lines.append("\(heading) Blocked")
            lines.append("")
            lines.append("These tools were requested and denied by the task's permissions: "
                + deniedTools.map { "`\($0)`" }.joined(separator: ", "))
            lines.append("")
        }

        var footer: [String] = []
        if let record { footer.append("Status: \(record.status.displayName)") }
        if let record { footer.append("Duration: \(RelativeTime.short(record.duration()))") }
        if let costUSD { footer.append(String(format: "Cost: $%.4f", costUSD)) }
        if let turns { footer.append("Turns: \(turns)") }
        if !footer.isEmpty {
            lines.append("---")
            lines.append("")
            lines.append(footer.joined(separator: " · "))
        }

        return lines
    }
}

/// One turn of a conversation: the run, and what it produced.
///
/// A thread is these in order. They are grouped by session ID rather than by
/// task, because running the same task twice starts two separate conversations.
struct RunTurn: Identifiable, Sendable {
    var record: TaskRunRecord
    var transcript: RunTranscript

    var id: UUID { record.id }

    /// Reads each run's log back into a readable turn.
    static func thread(_ records: [TaskRunRecord]) -> [RunTurn] {
        records.map { record in
            RunTurn(
                record: record,
                transcript: record.logFileURL.map { RunTranscript.parse(logURL: $0) } ?? RunTranscript()
            )
        }
    }
}
