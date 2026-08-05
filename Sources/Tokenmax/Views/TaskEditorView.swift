import AppKit
import SwiftUI

struct TaskEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var modelCatalog: ModelCatalogStore

    @State private var draft: TokenmaxTask
    /// Whether macOS is blocking reads of the chosen directory. Computed off
    /// the main thread by `refreshDirectoryPermission` — never in `body`.
    @State private var directoryNeedsPermission = false
    @FocusState private var focusedField: Field?
    private let onSave: (TokenmaxTask) -> Void

    private enum Field {
        case title
        case prompt
    }

    init(task: TokenmaxTask, onSave: @escaping (TokenmaxTask) -> Void) {
        _draft = State(initialValue: task)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            editorHeader

            // Scrolled rather than grown: the automation section roughly
            // doubled this sheet's height, and a sheet taller than the display
            // puts Save out of reach.
            ScrollView {
                editorFields.padding(.horizontal, 18)
            }
            .frame(maxHeight: 540)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Task") {
                    draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft.updatedAt = Date()
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            .padding(18)
        }
        .frame(width: 560)
        .onAppear {
            if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                focusedField = .title
            }
            // The editor is the only place the model list is read, so this is
            // where it is kept current. No-ops unless the cache is a day old.
            modelCatalog.refreshIfStale()
        }
    }

    /// Three sections, in the order the decisions are made: what the task is,
    /// how it should run, and what it is allowed to touch.
    ///
    /// The grouping matters most for the third — the permissions were
    /// previously a pair of checkboxes sitting in the same undifferentiated run
    /// of fields as the project name, which is not the weight they deserve.
    private var editorFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("Task", "Describe the work and its project context.", systemImage: "square.and.pencil") {
                contentFields
            }

            section("Execution", "Set the automation, limits, and model.", systemImage: "bolt") {
                executionFields
            }

            section("Permissions", "Control what the agent can change or run.", systemImage: "lock.shield") {
                permissionFields
            }
        }
        .padding(.vertical, 4)
    }

    private func section(
        _ title: String,
        _ subtitle: String,
        systemImage: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sectionBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var editorHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: draft.title.isEmpty ? "plus" : "pencil")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 1) {
                Text(draft.title.isEmpty ? "New task" : "Edit task")
                    .font(.system(size: 17, weight: .semibold))
                Text("Set up the work, execution, and access in one place.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private var contentFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("Title") {
                TextField("Generate tests for invoice parser", text: $draft.title)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .title)
            }

            field("Prompt") {
                TextEditor(text: $draft.prompt)
                    .font(.system(size: 12))
                    .frame(height: 128)
                    .focused($focusedField, equals: .prompt)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                    }
                HStack {
                    Text("Describe the work Claude should perform.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(draft.prompt.count) characters")
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 10))
            }

            HStack(spacing: 12) {
                field("Priority") {
                    Picker("", selection: $draft.priority) {
                        ForEach(TaskPriority.allCases) { priority in
                            Text(priority.displayName).tag(priority)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150, alignment: .leading)
                }
                field("Project") {
                    TextField("Optional", text: Binding(
                        get: { draft.projectName ?? "" },
                        set: { draft.projectName = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            field("Working directory") {
                HStack(spacing: 6) {
                    TextField("~/Projects/App", text: Binding(
                        get: { draft.workingDirectory ?? "" },
                        set: { draft.workingDirectory = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))

                    Button("Choose…") { chooseDirectory() }
                }
                .task(id: draft.workingDirectory) { await refreshDirectoryPermission() }
            }

            if let directory = draft.workingDirectory, !directory.isEmpty, !draft.workingDirectoryExists {
                Label("That directory does not exist yet.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            } else if directoryNeedsPermission {
                // Raised here, while the user is sitting in front of the editor,
                // because this is the only moment they can answer it. An
                // unattended run that meets the consent dialog at 3am blocks
                // until its runtime limit kills it.
                VStack(alignment: .leading, spacing: 5) {
                    Label(
                        "macOS is blocking Tokenmax from reading this folder.",
                        systemImage: "lock.fill"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)

                    Text("Unattended runs cannot answer a permission prompt, so this task would never start.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        Button("Grant Access…") { requestDirectoryAccess() }
                        Button("Open Settings") { openFilesAndFoldersSettings() }
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    // MARK: - Execution

    private var executionFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automation")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Choose how Tokenmax may start this task.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Picker("", selection: $draft.executionMode) {
                    Text("Manual only").tag(ExecutionMode.manual)
                    Text("Ask before running").tag(ExecutionMode.askBeforeRunning)
                    Text("Allow once during the current session").tag(ExecutionMode.approvedForSession)
                    Text("Always allow automatic execution").tag(ExecutionMode.automatic)
                }
                .labelsHidden()
                .frame(width: 218)
            }
            .padding(10)
            .background(settingBackground, in: RoundedRectangle(cornerRadius: 9))

            executionModeCallout

            Divider().padding(.vertical, 1)

            configurationGroup("Runtime and budget") {
                HStack(alignment: .top, spacing: 16) {
                    estimatedRuntimeField
                        .frame(width: 128, alignment: .leading)

                    field("Runtime limit") {
                        Picker("", selection: runtimeLimit) {
                            ForEach(runtimeOptions, id: \.self) { minutes in
                                Text("\(minutes) min").tag(minutes)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 128, alignment: .leading)
                    }
                    .frame(width: 128, alignment: .leading)

                    if draft.provider == .claudeCode {
                        field("Spend limit") {
                            Picker("", selection: $draft.autoRun.maximumBudgetUSD) {
                                ForEach(TaskExecutionPolicy.budgetOptions, id: \.self) { value in
                                    Text(String(format: "$%.2f", value)).tag(value)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 112, alignment: .leading)
                        }
                        .frame(width: 112, alignment: .leading)
                    }

                    Spacer(minLength: 0)
                }
            }

            configurationGroup("Model preferences") {
                HStack(alignment: .top, spacing: 12) {
                    if draft.provider == .claudeCode {
                        claudeModelField
                        field("Thinking") {
                            Picker("", selection: effortBinding(
                                get: { draft.autoRun.effort },
                                set: { draft.autoRun.effort = $0 }
                            )) {
                                Text("Default").tag("")
                                ForEach(availableEffortLevels, id: \.self) { level in
                                    Text(TaskExecutionPolicy.effortDisplayName(level)).tag(level)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 120, alignment: .leading)
                            // Several 4.5-era models have no effort control at all.
                            // Offering them a grade would be a lie the CLI rejects.
                            .disabled(availableEffortLevels.isEmpty)
                        }
                    } else {
                        field("Model") {
                            TextField("Codex default", text: Binding(
                                get: { draft.codex.model ?? "" },
                                set: { draft.codex.model = $0.isEmpty ? nil : $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                        }
                        field("Reasoning") {
                            Picker("", selection: effortBinding(
                                get: { draft.codex.reasoningEffort },
                                set: { draft.codex.reasoningEffort = $0 }
                            )) {
                                Text("Config default").tag("")
                                ForEach(CodexExecutionPolicy.reasoningEffortOptions, id: \.self) { level in
                                    Text(level.capitalized).tag(level)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 150, alignment: .leading)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            if draft.executionMode != .manual, draft.estimatedMinutes == nil {
                Text("An estimate is required for automatic runs.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var estimatedRuntimeField: some View {
        field("Estimated runtime") {
            HStack(spacing: 5) {
                TextField("15", value: $draft.estimatedMinutes, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                Text("min")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var executionModeCallout: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
            Text(executionModeExplanation)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    /// Says what the selected mode actually means, next to where it is picked.
    /// Four radio labels alone leave the difference between "ask" and "allow
    /// once" to be guessed at.
    private var executionModeExplanation: String {
        switch draft.executionMode {
        case .manual:
            "Tokenmax never starts this on its own. You can still run it yourself from the queue."
        case .askBeforeRunning:
            "Tokenmax notifies you when this could run, and waits for you to start it."
        case .approvedForSession:
            "Tokenmax may start this without asking, once, during the current session window."
        case .automatic:
            "Tokenmax may start this without asking whenever the queue's conditions are met."
        }
    }

    // MARK: - Permissions

    private var permissionFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            if draft.provider == .codex {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sandbox")
                            .font(.system(size: 12, weight: .semibold))
                        Text(draft.codex.sandbox.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    Picker("Sandbox", selection: $draft.codex.sandbox) {
                        ForEach(CodexSandbox.allCases) { sandbox in
                            Text(sandbox.displayName).tag(sandbox)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
                .padding(10)
                .background(settingBackground, in: RoundedRectangle(cornerRadius: 9))

                Text("Codex may run commands inside this sandbox. Tokenmax cannot enforce a per-run USD cap for Codex.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                permissionToggle(
                    "Allow file changes",
                    detail: "The agent can edit files in the working directory.",
                    systemImage: "doc.badge.gearshape",
                    isOn: $draft.autoRun.allowFileChanges
                )

                permissionToggle(
                    "Allow shell commands",
                    detail: "Commands can reach beyond the working directory.",
                    systemImage: "terminal",
                    isOn: $draft.autoRun.allowShellCommands
                )

                capabilityDisclosure
            }
        }
    }

    private func permissionToggle(
        _ title: String,
        detail: String,
        systemImage: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(title)
        }
        .padding(10)
        .background(settingBackground, in: RoundedRectangle(cornerRadius: 9))
    }

    /// Aliases, then every model the account can actually use, then "Other…".
    ///
    /// Both lists come from the fetched catalog, so a model released after this
    /// build shipped appears here on its own. Aliases stay first because they
    /// are the right default — `--model opus` resolves to the newest Opus at run
    /// time, where a pinned id stays on the build you chose.
    @ViewBuilder
    private var claudeModelField: some View {
        field("Model") {
            Picker("", selection: modelSelection) {
                ForEach(aliases, id: \.self) { alias in
                    Text(TaskExecutionPolicy.modelDisplayName(alias)).tag(alias)
                }
                if !modelCatalog.models.isEmpty {
                    Divider()
                    ForEach(modelCatalog.models) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                Divider()
                Text("Other…").tag(Self.customModelTag)
            }
            .labelsHidden()
            .frame(width: 190, alignment: .leading)

            if isCustomModel {
                TextField("claude-opus-5", text: $draft.autoRun.model)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 190)
            } else if let resolved = resolvedModelHint {
                Text(resolved)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Sentinel that cannot collide with a real model id.
    private static let customModelTag = "\u{0}custom"

    private var aliases: [String] { modelCatalog.aliases }

    /// Every value the picker can represent without falling back to free text.
    private var knownModels: [String] { aliases + modelCatalog.models.map(\.id) }

    private var isCustomModel: Bool {
        !knownModels.contains(draft.autoRun.model)
    }

    /// What the chosen alias resolves to today. Only shown for aliases — for a
    /// pinned id the picker already says the same thing.
    private var resolvedModelHint: String? {
        guard aliases.contains(draft.autoRun.model),
              let name = modelCatalog.resolvedName(for: draft.autoRun.model)
        else { return nil }
        return "currently \(name)"
    }

    private var availableEffortLevels: [String] {
        modelCatalog.effortLevels(for: draft.autoRun.model)
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { isCustomModel ? Self.customModelTag : draft.autoRun.model },
            set: { selected in
                // Switching *to* "Other…" clears the field rather than leaving
                // the previous alias in it, which would read as already-pinned.
                draft.autoRun.model = selected == Self.customModelTag ? "" : selected
                // A model that does not support the currently-chosen grade must
                // not silently keep it — the CLI would reject the run.
                if let effort = draft.autoRun.effort,
                   !modelCatalog.effortLevels(for: draft.autoRun.model).contains(effort) {
                    draft.autoRun.effort = nil
                }
            }
        )
    }

    /// Bridges `String?` storage to a picker, which cannot select nil. The empty
    /// tag is "leave the flag off".
    private func effortBinding(
        get: @escaping () -> String?,
        set: @escaping (String?) -> Void
    ) -> Binding<String> {
        Binding(
            get: { get() ?? "" },
            set: { set($0.isEmpty ? nil : $0) }
        )
    }

    private var runtimeOptions: [Int] {
        draft.provider == .codex ? CodexExecutionPolicy.runtimeOptions : TaskExecutionPolicy.runtimeOptions
    }

    private var runtimeLimit: Binding<Int> {
        Binding(
            get: { draft.provider == .codex ? draft.codex.maximumRuntimeMinutes : draft.autoRun.maximumRuntimeMinutes },
            set: { value in
                if draft.provider == .codex { draft.codex.maximumRuntimeMinutes = value }
                else { draft.autoRun.maximumRuntimeMinutes = value }
            }
        )
    }

    /// Restates the two checkboxes as what they actually grant.
    ///
    /// The consequence of mis-setting them is unattended edits to a real
    /// repository, and a checkbox buried in a form is easy to mis-set — so the
    /// grant is spelled out where the decision is made rather than left to be
    /// inferred from the label.
    private var capabilityDisclosure: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Current access")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(draft.autoRun.capabilitySummary, id: \.label) { capability in
                HStack(spacing: 6) {
                    Image(systemName: capability.granted ? "checkmark.square.fill" : "square")
                        .font(.system(size: 10))
                        .foregroundStyle(capability.granted ? Color.accentColor : Color.secondary)
                    Text(capability.label)
                        .font(.system(size: 11))
                        .foregroundStyle(capability.granted ? .primary : .secondary)
                }
            }

            if draft.autoRun.escapesWorkingDirectory {
                Text("Shell commands are not limited to the working directory.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(settingBackground, in: RoundedRectangle(cornerRadius: 9))
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func configurationGroup(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            content()
        }
    }

    private var sectionBackground: Color {
        Color.primary.opacity(0.035)
    }

    private var settingBackground: Color {
        Color.primary.opacity(0.055)
    }

    /// Re-checks whether the directory can be read, off the main thread.
    ///
    /// Never called from `body`. The check lists the directory and opens a file
    /// in it, and the first such call blocks until the consent dialog is
    /// answered — neither of which belongs in a view evaluation that SwiftUI
    /// runs on every redraw of a large checkout.
    ///
    /// Debounced because the path is a text field: typing it out otherwise
    /// probes once per keystroke.
    private func refreshDirectoryPermission(debounced: Bool = true) async {
        // Skipped when the user pressed the button: they are waiting on it.
        if debounced {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
        }

        let candidate = draft
        guard let directory = candidate.workingDirectory, !directory.isEmpty else {
            directoryNeedsPermission = false
            return
        }

        let blocked = await Task.detached(priority: .userInitiated) {
            candidate.workingDirectoryExists && !candidate.workingDirectoryReadable
        }.value

        guard !Task.isCancelled else { return }
        directoryNeedsPermission = blocked
    }

    /// Deliberately performs a real read: that is what raises the consent
    /// dialog. There is no API to ask macOS for TCC access directly — you ask
    /// for the data and the system arbitrates.
    /// There is no API for "please ask the user for TCC access" — you attempt
    /// the protected operation and the system arbitrates. So the request *is*
    /// the probe: `workingDirectoryReadable` opens a file, which is the only
    /// thing here macOS gates.
    ///
    /// It listed the directory first, which was pointless: listing is not gated,
    /// so that call could never raise the dialog it existed to raise. Anything
    /// added here must be an operation TCC actually refuses, or it is theatre.
    private func requestDirectoryAccess() {
        Task { await refreshDirectoryPermission(debounced: false) }
    }

    private func openFilesAndFoldersSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Store with ~ so the path stays readable and portable.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        draft.workingDirectory = url.path.hasPrefix(home)
            ? "~" + url.path.dropFirst(home.count)
            : url.path

        if draft.projectName == nil || draft.projectName?.isEmpty == true {
            draft.projectName = url.lastPathComponent
        }
    }
}
