import Domain
import Pulse
import SwiftUI

/// One Night's account, laid out as the Journal recorded it: the Night's facts, then its Act runs in the
/// order they began. Problems come first by default: the toggle starts on, so only the runs with a
/// problem, and in them only the problem entries, are listed, and an absence is stated. A run with a
/// problem starts expanded; the others start collapsed.
struct NightDetailAccount: View {
    let account: NightAccount
    @State private var problemsOnly = true
    @State private var expanded: Set<String>

    init(account: NightAccount) {
        self.account = account
        _expanded = State(initialValue: Set(account.runs.filter(\.hasProblem).map(\.id)))
    }

    var body: some View {
        Section("Details") {
            NightFact(label: "Opened", value: account.openedAt.formatted(date: .abbreviated, time: .standard))
            NightFact(
                label: "Closed",
                value: account.completedAt?.formatted(date: .abbreviated, time: .standard) ?? "not closed"
            )
            if let reason = account.closeReason {
                NightFact(label: "Close reason", value: reason)
            }
            NightFact(label: "Act runs", value: "\(account.runs.count)")
            NightFact(label: "Problems", value: "\(account.problemCount)", identifier: "night-detail-problem-count")
        }
        Section("Act runs") {
            Toggle("Problems only", isOn: $problemsOnly)
                .accessibilityIdentifier("night-detail-problems-only")
            if problemsOnly, account.problemCount == 0 {
                Text("No problems recorded this Night.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("night-detail-no-problems")
            }
            ForEach(Array(account.runs.enumerated()), id: \.element.id) { index, run in
                if !problemsOnly || run.hasProblem {
                    DisclosureGroup(isExpanded: isExpanded(run)) {
                        NightRunEntries(entries: run.entries.filter { !problemsOnly || $0.isProblem })
                            .padding(.top, 4)
                    } label: {
                        NightRunLabel(run: run)
                    }
                    .accessibilityIdentifier("night-detail-run-\(index + 1)")
                }
            }
        }
    }

    private func isExpanded(_ run: NightAccount.ActRun) -> Binding<Bool> {
        Binding {
            expanded.contains(run.id)
        } set: { isExpanded in
            if isExpanded { expanded.insert(run.id) } else { expanded.remove(run.id) }
        }
    }
}

/// A run's row: its Act and start time over how it ended.
private struct NightRunLabel: View {
    let run: NightAccount.ActRun

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.callout.weight(.semibold))
            // A run with no closing event is only "not ended": with no live run behind it, it is what a
            // killed invocation leaves, so it is never called running here.
            Text(run.outcome.words)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        guard let act = run.act else { return "No Act run" }
        return "\(act.capitalized) Act \u{00B7} \(run.startedAt.formatted(.dateTime.hour().minute()))"
    }
}

/// A run expanded in place: its entries in append order.
private struct NightRunEntries: View {
    let entries: [NightAccount.Entry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(entries) { entry in
                NightEntryRow(entry: entry)
            }
        }
        .textSelection(.enabled)
    }
}

/// One Journal event in plain words. A problem carries the Health group's warning mark, and its headline
/// says what happened, so colour is never the only signal.
private struct NightEntryRow: View {
    let entry: NightAccount.Entry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.occurredAt.formatted(.dateTime.hour().minute().second()))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if entry.isProblem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.warning)
                    .accessibilityLabel("Problem")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.headline)
                if let detail = entry.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A labelled value, one form row. The identifier goes on the value, so a test reads the value alone.
private struct NightFact: View {
    let label: LocalizedStringKey
    let value: String
    var identifier: String?

    var body: some View {
        LabeledContent(label) {
            Text(value)
                .textSelection(.enabled)
                .accessibilityIdentifier(identifier ?? "")
        }
    }
}

private extension NightAccount.RunOutcome {
    /// How the run ended, in plain words. Never "running".
    var words: String {
        switch self {
        case .ended: "ended"
        case .idle(let reason): "idle \u{2014} \(reason)"
        case .incomplete(let reason): "could not complete \u{2014} \(reason)"
        case .stoodDown: "stood down"
        case .notEnded: "not ended"
        }
    }
}
