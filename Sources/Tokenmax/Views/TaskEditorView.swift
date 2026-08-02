import AppKit
import SwiftUI

struct TaskEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: TokenmaxTask
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
            Text(draft.title.isEmpty ? "New Task" : "Edit Task")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 14)

            // Scrolled rather than grown: the automation section roughly
            // doubled this sheet's height, and a sheet taller than the display
            // puts Save out of reach.
            ScrollView {
                editorFields.padding(.horizontal, 18)
            }
            .frame(maxHeight: 460)

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
        .frame(width: 500)
        .onAppear {
            if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                focusedField = .title
            }
        }
    }

    private var editorFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("Title") {
                TextField("Generate tests for invoice parser", text: $draft.title)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .title)
            }

            field("Prompt") {
                TextEditor(text: $draft.prompt)
                    .font(.system(size: 12))
                    .frame(height: 150)
                    .focused($focusedField, equals: .prompt)
                    .padding(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
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
                }
                field("Project") {
                    TextField("Optional", text: Binding(
                        get: { draft.projectName ?? "" },
                        set: { draft.projectName = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
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
            }

            if let directory = draft.workingDirectory, !directory.isEmpty, !draft.workingDirectoryExists {
                Label("That directory does not exist yet.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }

            Divider()

            automationSection
        }
        .padding(.bottom, 4)
    }

    // MARK: - Automation

    private var automationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("Automatic execution") {
                Picker("", selection: $draft.executionMode) {
                    Text("Manual only").tag(ExecutionMode.manual)
                    Text("Ask before running").tag(ExecutionMode.askBeforeRunning)
                    Text("Allow once during the current session").tag(ExecutionMode.approvedForSession)
                    Text("Always allow automatic execution").tag(ExecutionMode.automatic)
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
            }

            HStack(alignment: .top, spacing: 12) {
                field("Estimated runtime") {
                    HStack(spacing: 4) {
                        TextField("15", value: $draft.estimatedMinutes, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 52)
                        Text("min").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }

                field("Runtime limit") {
                    Picker("", selection: $draft.autoRun.maximumRuntimeMinutes) {
                        ForEach(TaskExecutionPolicy.runtimeOptions, id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 96)
                }

                field("Model") {
                    Picker("", selection: $draft.autoRun.model) {
                        ForEach(TaskExecutionPolicy.modelOptions, id: \.self) { model in
                            Text(TaskExecutionPolicy.modelDisplayName(model)).tag(model)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 96)
                }

                field("Spend limit") {
                    Picker("", selection: $draft.autoRun.maximumBudgetUSD) {
                        ForEach(TaskExecutionPolicy.budgetOptions, id: \.self) { value in
                            Text(String(format: "$%.2f", value)).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 88)
                }
            }

            // The runtime limit, not the estimate, is what decides whether this
            // task can start before a reset — so say so where it is set.
            if draft.estimatedMinutes == nil {
                Label(
                    "Automatic runs need an estimate. It is what the queue shows you; the runtime limit is what actually stops the task.",
                    systemImage: "info.circle"
                )
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 16) {
                Toggle("Allow file changes", isOn: $draft.autoRun.allowFileChanges)
                Toggle("Allow shell commands", isOn: $draft.autoRun.allowShellCommands)
            }
            .font(.system(size: 11))
            .toggleStyle(.checkbox)

            capabilityDisclosure
        }
    }

    /// Restates the two checkboxes as what they actually grant.
    ///
    /// The consequence of mis-setting them is unattended edits to a real
    /// repository, and a checkbox buried in a form is easy to mis-set — so the
    /// grant is spelled out where the decision is made rather than left to be
    /// inferred from the label.
    private var capabilityDisclosure: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("WHEN TOKENMAX RUNS THIS TASK, IT MAY")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)

            ForEach(draft.autoRun.capabilitySummary, id: \.label) { capability in
                HStack(spacing: 5) {
                    Image(systemName: capability.granted ? "checkmark.square.fill" : "square")
                        .font(.system(size: 9))
                        .foregroundStyle(capability.granted ? Color.accentColor : Color.secondary)
                    Text(capability.label)
                        .font(.system(size: 10))
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
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            content()
        }
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
