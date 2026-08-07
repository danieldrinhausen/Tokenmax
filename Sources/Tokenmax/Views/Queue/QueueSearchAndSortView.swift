import SwiftUI

/// Search and sort for the visible list.
///
/// Neither writes anything. Sorting is a lens on the queue, not a change to it —
/// `sortIndex` is untouched, so what the auto-runner picks up next is exactly
/// what it would have picked up before the user changed the sort.
struct QueueSearchAndSortView: View {
    @Binding var query: String
    @Binding var sort: QueueSort
    /// nil is "every provider". Shown only when there is more than one to
    /// choose between — a filter with a single option is furniture.
    @Binding var provider: TokenmaxProvider?
    let providerOptions: [TokenmaxProvider]
    /// Off while a sort other than queue order is active, so the menu can say
    /// why the drag handles have gone.
    let canReorder: Bool

    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            searchField

            if providerOptions.count > 1 {
                providerMenu
            }

            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(QueueSort.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.inline)

                if !canReorder {
                    Divider()
                    Text("Switch to Queue Order to reorder tasks by dragging")
                }
            } label: {
                Label(sort.displayName, systemImage: "arrow.up.arrow.down")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Change how the list is ordered. This does not change the queue itself.")
            .accessibilityLabel("Sort order, currently \(sort.displayName)")
        }
    }

    private var providerMenu: some View {
        Menu {
            Picker("Provider", selection: $provider) {
                Text("All providers").tag(TokenmaxProvider?.none)
                ForEach(providerOptions) { option in
                    Text(option.displayName).tag(TokenmaxProvider?.some(option))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(provider?.displayName ?? "All providers", systemImage: "line.3.horizontal.decrease")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Show only tasks for one provider. This does not change the queue itself.")
        .accessibilityLabel("Provider filter, currently \(provider?.displayName ?? "all providers")")
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            TextField("Search tasks", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($searchFocused)
                .accessibilityLabel("Search tasks by title, prompt, project, or directory")

            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        .frame(maxWidth: 240)
    }
}
