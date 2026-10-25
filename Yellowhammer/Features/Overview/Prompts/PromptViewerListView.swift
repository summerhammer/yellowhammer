import Domain
import Pulse
import SwiftUI

/// The left pane dispatch list: displays rows of dispatches or distinct empty states.
struct PromptViewerListView: View {
    let items: [DispatchPromptItem]
    let emptyState: DispatchPromptIndex.EmptyState?
    @Binding var selectedItemID: String?

    var body: some View {
        Group {
            if let emptyState {
                emptyStateView(emptyState)
            } else if items.isEmpty {
                emptyStateView(.noDispatchesYet)
            } else {
                List(selection: $selectedItemID) {
                    ForEach(items) { item in
                        PromptDispatchRow(item: item)
                            .tag(item.id)
                            .accessibilityIdentifier("prompts-dispatch-row-\(item.id)")
                    }
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier("prompts-dispatch-list")
            }
        }
    }

    @ViewBuilder
    private func emptyStateView(_ state: DispatchPromptIndex.EmptyState) -> some View {
        VStack(spacing: 8) {
            switch state {
            case .noDispatchesYet:
                Text("No Dispatches Yet")
                    .font(.headline)
                Text("No dispatches have been recorded yet for this Attempt.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case let .skipped(reason):
                Text("Pass Skipped")
                    .font(.headline)
                Text("Pass was skipped: \(reason)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .legacy:
                Text("Legacy History")
                    .font(.headline)
                Text("This dispatch occurred before prompt capture was supported.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("prompts-empty-state")
    }
}

/// One row in the prompt viewer dispatch list.
struct PromptDispatchRow: View {
    let item: DispatchPromptItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.body.weight(.semibold))
                Spacer()
                Text(item.time.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Text(item.route)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(item.isResumed ? "Resumed" : "New")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(item.isResumed ? .blue.opacity(0.15) : .secondary.opacity(0.12), in: .capsule)
                stateBadge
            }
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        var parts: [String] = [item.pass.rawValue.capitalized]
        if let round = item.round {
            parts.append("Round \(round)")
        }
        if let routeTry = item.routeTry {
            parts.append("Try \(routeTry)")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch item.state {
        case .recorded:
            EmptyView()
        case .expired:
            Text("Expired")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.orange.opacity(0.15), in: .capsule)
        case .deleted:
            Text("Deleted")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.red)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.red.opacity(0.15), in: .capsule)
        case .unavailable:
            Text("Unavailable")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.secondary.opacity(0.15), in: .capsule)
        case .rehearsal:
            Text("Rehearsal")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.purple)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.purple.opacity(0.15), in: .capsule)
        }
    }
}
