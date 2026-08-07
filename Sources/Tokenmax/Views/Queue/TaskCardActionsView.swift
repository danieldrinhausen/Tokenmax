import SwiftUI

/// Everything a card can do, in one bundle.
///
/// Passed as a struct rather than fifteen closure parameters so the card views
/// stay readable, and so `TaskAction` — which decides *which* actions a state
/// offers — can be turned into a callback without every view knowing the map.
struct TaskCardActions {
    var edit: () -> Void = {}
    var copyPrompt: () -> Void = {}
    var openInTerminal: () -> Void = {}
    var runWithProvider: () -> Void = {}
    var stop: () -> Void = {}
    var viewOutput: () -> Void = {}
    var markComplete: () -> Void = {}
    var retry: () -> Void = {}
    var restore: () -> Void = {}
    var moveToTop: () -> Void = {}
    var duplicate: () -> Void = {}
    var archive: () -> Void = {}
    var delete: () -> Void = {}

    func callback(for action: TaskAction) -> () -> Void {
        switch action {
        case .edit: edit
        case .copyPrompt: copyPrompt
        case .openInTerminal: openInTerminal
        case .runWithProvider: runWithProvider
        case .stop: stop
        // All three read the same run record; they differ only in what the
        // button promises, which is what the user is looking for at the time.
        case .viewResult, .viewOutput, .viewError: viewOutput
        case .markComplete: markComplete
        case .retry: retry
        case .restore: restore
        case .moveToTop: moveToTop
        case .duplicate: duplicate
        case .archive: archive
        case .delete: delete
        }
    }
}

/// One prominent action, a few plain ones, and a menu for the rest.
///
/// The rule this enforces is the one the old card broke: exactly one action is
/// styled as the thing to do. Four equally-weighted buttons make the user read
/// all four every time; one prominent button and two quiet ones can be used
/// without reading anything.
struct TaskCardActionsView: View {
    let actions: TaskActionSet
    let handlers: TaskCardActions
    /// Set while the copy confirmation is showing, owned by the parent so the
    /// label change survives the card being re-created on a redraw.
    @Binding var copied: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(actions.secondary) { action in
                Button(label(for: action)) { handlers.callback(for: action)() }
                    .accessibilityLabel(action.title)
            }

            Spacer(minLength: 6)

            Button(actions.primary.title) { handlers.callback(for: actions.primary)() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel(actions.primary.title)

            if !actions.overflow.isEmpty {
                overflowMenu
            }
        }
        .font(.system(size: 11))
    }

    private func label(for action: TaskAction) -> String {
        action == .copyPrompt && copied ? "Copied" : action.title
    }

    private var overflowMenu: some View {
        Menu {
            ForEach(actions.overflow) { action in
                if action.isDestructive {
                    Divider()
                    Button(action.title, role: .destructive) { handlers.callback(for: action)() }
                } else {
                    Button(action.title) { handlers.callback(for: action)() }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        // Without this the control renders as an ellipsis *and* a chevron,
        // which reads as two adjacent affordances rather than one menu.
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions")
    }
}
