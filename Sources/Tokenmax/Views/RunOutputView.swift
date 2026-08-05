import AppKit
import SwiftUI

/// What a run produced, in a form worth reading — and a way to continue it.
///
/// The raw log is newline-delimited JSON: complete, and unreadable. This answers
/// the question the user actually has ("what did it say?") first, keeps the
/// mechanics underneath it, and lets them reply.
///
/// A reply matters because `claude -p` cannot ask a question and wait. When a
/// run needs a decision it says so in its final message and exits, and without
/// somewhere to answer, the only way forward is to start over with a longer
/// prompt.
struct RunOutputView: View {
    /// Any turn of the conversation; the whole thread is loaded from it.
    let record: TaskRunRecord

    @EnvironmentObject private var autoRun: QueueAutoRunCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var turns: [RunTurn] = []
    @State private var replyBlock: QueueAutoRunDecision.SkipReason?
    @State private var expandedActivity: Set<UUID> = []
    @State private var replyText = ""
    @State private var replyError: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                            turnView(turn, isFirst: index == 0)
                                .id(turn.id)
                        }
                        liveProgress
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // A reply lands at the bottom, which is off-screen in a long
                // thread — the answer to what you just asked should not have to
                // be scrolled to.
                .onChange(of: turns.count) {
                    guard let last = turns.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            Divider()
            replyBar
            footer
        }
        .frame(width: 620, height: 620)
        .onAppear(perform: load)
        .onChange(of: threadSignature) { load() }
    }

    // MARK: - Loading

    /// Changes when a run starts, finishes, or changes status — but *not* on
    /// every progress line, which would re-read every log in the thread several
    /// times a second.
    private var threadSignature: String {
        [
            autoRun.activeRun?.id.uuidString ?? "-",
            autoRun.lastRun?.id.uuidString ?? "-",
            autoRun.lastRun?.status.rawValue ?? "-",
        ].joined(separator: "|")
    }

    private func load() {
        turns = RunTurn.thread(autoRun.thread(containing: record))
        replyBlock = latest.map { autoRun.replyBlock(for: $0.record) } ?? .notResumable
    }

    private var latest: RunTurn? { turns.last }

    /// True while a run belonging to *this* task is in flight. The reply field
    /// closes for any run, but only this thread's run shows its progress here.
    private var isRunningHere: Bool {
        autoRun.activeRun?.taskID == record.taskID && autoRun.activeRun != nil
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(record.taskTitle)
                .font(.system(size: 15, weight: .semibold))
            Text(metaLine)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if !record.workingDirectory.isEmpty {
                // Which copy of the project this ran against is not a detail
                // when two checkouts of the same repo are open.
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                    Text(record.workingDirectory)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .foregroundStyle(.tertiary)
                .help(record.workingDirectory)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var metaLine: String {
        var parts: [String] = []
        if let latest { parts.append(latest.record.status.displayName) }
        if turns.count > 1 { parts.append("\(turns.count) turns") }
        parts.append(record.startedAt.formatted(date: .abbreviated, time: .shortened))
        if let duration { parts.append(duration) }
        parts.append(TaskExecutionPolicy.modelDisplayName(record.model))
        // Only when it was set — "Default" in the metadata line would be noise
        // on the runs that never asked for a thinking grade.
        if let effort = record.effort, !effort.isEmpty {
            parts.append("\(TaskExecutionPolicy.effortDisplayName(effort)) effort")
        }
        if let cost = totalCost {
            // The thread total, not the last turn's: each turn replays the whole
            // conversation, so the running cost is the number that matters.
            parts.append(String(format: "$%.4f", cost))
        }
        return parts.joined(separator: " · ")
    }

    /// Wall-clock time across the whole thread, from the first turn starting to
    /// the last one finishing. Absent while a run is still in flight rather than
    /// counting up — the live progress line already says it is working.
    private var duration: String? {
        guard let first = turns.first?.record.startedAt ?? Optional(record.startedAt),
              let last = turns.last?.record.finishedAt
        else { return nil }
        return RelativeTime.short(last.timeIntervalSince(first))
    }

    private var totalCost: Double? {
        let costs = turns.compactMap { $0.transcript.costUSD ?? $0.record.costUSD }
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    // MARK: - One turn

    @ViewBuilder
    private func turnView(_ turn: RunTurn, isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !isFirst {
                Divider()
            }
            if let reply = turn.record.replyText, !reply.isEmpty {
                askedView(reply)
            }
            resultSection(turn)
            deniedSection(turn)
            activitySection(turn)
        }
    }

    private func askedView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("You asked")
            Text(text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
    }

    /// Falls back to the persisted `resultText` when the log has been truncated
    /// or removed — the answer is on the record precisely so it survives that.
    private func answer(_ turn: RunTurn) -> String? {
        let value = turn.transcript.result ?? turn.record.resultText
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    @ViewBuilder
    private func resultSection(_ turn: RunTurn) -> some View {
        if let answer = answer(turn) {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Result")
                Text(rendered(answer))
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let errorMessage = turn.record.errorMessage {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("What went wrong")
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Result")
                Text(emptyResultMessage(turn))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A run with no final message is not necessarily a run with nothing to
    /// show — the log holds everything the CLI streamed. Saying so is the
    /// difference between "empty" and "look over there".
    private func emptyResultMessage(_ turn: RunTurn) -> String {
        guard turn.record.status.isFinished else { return "Still running…" }
        if turn.record.logFileURL != nil {
            return "This run did not produce a final message. The raw log below has everything it streamed."
        }
        return "This run did not produce a final message, and its log is no longer available."
    }

    /// Inline Markdown — bold, code spans, links — which is most of what a
    /// final message uses. Falls back to the raw string rather than failing.
    private func rendered(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }

    // MARK: - Denials

    @ViewBuilder
    private func deniedSection(_ turn: RunTurn) -> some View {
        if !turn.transcript.deniedTools.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                sectionTitle("Blocked by this task's permissions")
                // The usual explanation for a run that looks like it
                // under-delivered, so it is called out rather than buried.
                Text(Set(turn.transcript.deniedTools).sorted().joined(separator: ", "))
                    .font(.system(size: 11, design: .monospaced))
                Text("Edit the task to allow these if the result looks incomplete.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    // MARK: - Activity

    @ViewBuilder
    private func activitySection(_ turn: RunTurn) -> some View {
        let tools = turn.transcript.entries.compactMap { entry -> (String, String?)? in
            if case let .tool(name, detail) = entry { return (name, detail) }
            return nil
        }
        let isExpanded = expandedActivity.contains(turn.id)

        if !tools.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    if isExpanded {
                        expandedActivity.remove(turn.id)
                    } else {
                        expandedActivity.insert(turn.id)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9))
                        sectionTitle("Activity (\(tools.count) steps)")
                    }
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                            HStack(spacing: 6) {
                                Text(tool.0)
                                    .font(.system(size: 10, weight: .medium))
                                    .frame(width: 74, alignment: .leading)
                                if let detail = tool.1 {
                                    Text(detail)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                    }
                    .padding(.leading, 13)
                }
            }
        }
    }

    @ViewBuilder
    private var liveProgress: some View {
        if isRunningHere, let text = autoRun.progressText {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
    }

    // MARK: - Reply

    @ViewBuilder
    private var replyBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let replyBlock {
                Text(replyBlock == .notResumable
                    ? "This run was made before conversations were saved, so it cannot be continued. Runs from now on can."
                    : replyBlock.explanation)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Reply to continue this conversation…", text: $replyText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1 ... 4)
                        .font(.system(size: 12))
                        .onSubmit(send)

                    Button("Send", action: send)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let replyError {
                    Text(replyError)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private func send() {
        guard let latest else { return }
        let text = replyText
        if let reason = autoRun.reply(to: latest.record, text: text) {
            replyError = reason.explanation
            return
        }
        replyText = ""
        replyError = nil
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button(copied ? "Copied" : "Copy Result") { copyResult() }
                .disabled(latest.flatMap(answer) == nil)
            Button("Save as Markdown…") { exportMarkdown() }
            Button("Raw Log") { revealRawLog() }
                .disabled(latest?.record.logFileURL == nil)

            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .font(.system(size: 11))
        .padding(12)
    }

    private func copyResult() {
        guard let answer = latest.flatMap(answer) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(safeFileName(record.taskTitle)).md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let text = RunTranscript.markdown(title: record.taskTitle, turns: turns)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func safeFileName(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "tokenmax-run" : cleaned
    }

    private func revealRawLog() {
        guard let url = latest?.record.logFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
