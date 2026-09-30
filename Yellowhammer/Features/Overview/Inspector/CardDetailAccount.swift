import Domain
import Pulse
import SwiftUI

/// One Card's account, laid out as the Journal recorded it: the Card, its routes, then its Attempt
/// history oldest first. Each Attempt expands in place to its Rounds and Check runs; the latest one
/// starts expanded, because it holds the current Round.
struct CardDetailAccount: View {
    let detail: CardDetail
    @State private var expanded: Set<String>

    init(detail: CardDetail) {
        self.detail = detail
        _expanded = State(initialValue: Set(detail.attempts.last.map { [$0.id] } ?? []))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("Details") {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    fact("Repo", detail.repo)
                    fact("Kind", detail.kind)
                    fact("Budget epoch", "\(detail.budgetEpoch)")
                    fact("Attempts", "\(detail.attemptCount)", identifier: "card-detail-attempt-count")
                    fact("Rounds", "\(detail.roundCount)", identifier: "card-detail-round-count")
                }
            }
            section("Routes") {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    fact("Tried", routeList(detail.routesTried), identifier: "card-detail-routes-tried")
                    fact("Excluded", routeList(detail.excludedRoutes), identifier: "card-detail-routes-excluded")
                }
            }
            section("Attempts") {
                if detail.attempts.isEmpty {
                    Text("No Attempt has been recorded for this Card.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("card-detail-no-attempts")
                }
                ForEach(Array(detail.attempts.enumerated()), id: \.element.id) { index, attempt in
                    DisclosureGroup(isExpanded: isExpanded(attempt)) {
                        AttemptAccount(attempt: attempt)
                            .padding(.top, 4)
                    } label: {
                        AttemptLabel(number: index + 1, attempt: attempt)
                    }
                    .accessibilityIdentifier("card-detail-attempt-\(index + 1)")
                }
            }
        }
        .textSelection(.enabled)
    }

    private func isExpanded(_ attempt: CardDetail.Attempt) -> Binding<Bool> {
        Binding {
            expanded.contains(attempt.id)
        } set: { isExpanded in
            if isExpanded { expanded.insert(attempt.id) } else { expanded.remove(attempt.id) }
        }
    }

    private func routeList(_ routes: [String]) -> String {
        routes.isEmpty ? "none" : routes.joined(separator: ", ")
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

/// An Attempt's row: its number, route and outcome.
private struct AttemptLabel: View {
    let number: Int
    let attempt: CardDetail.Attempt

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Attempt \(number) \u{00B7} \(attempt.route)")
                .font(.callout.weight(.semibold))
            // An open Attempt is only "not ended": with no live run behind it, it is what a killed
            // invocation leaves, so it is never called running here.
            Text(attempt.result ?? "not ended")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// An Attempt expanded in place: how its route was chosen and how it ended, then its Rounds and the
/// Check runs over its work.
private struct AttemptAccount: View {
    let attempt: CardDetail.Attempt

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 2) {
                if let source = attempt.routeSource {
                    fact("Route source", source)
                }
                if let pin = attempt.overridePin {
                    fact("Override", pin)
                }
                fact("Started", attempt.startedAt.formatted(date: .abbreviated, time: .standard))
                fact("Ended", attempt.endedAt?.formatted(date: .abbreviated, time: .standard) ?? "not ended")
                if let classification = attempt.classification {
                    fact("Classification", classification)
                }
                if let consumedHow = attempt.consumedHow {
                    fact("Consumed", consumedHow)
                }
                if let preservedRef = attempt.preservedRef {
                    let preserved = [preservedRef, attempt.preservedCommit].compactMap(\.self)
                    fact("Preserved", preserved.joined(separator: " @ "))
                }
            }
            .font(.callout)
            ForEach(Array(attempt.rounds.enumerated()), id: \.element.id) { index, round in
                RoundRow(number: index + 1, round: round)
            }
            if attempt.checkDeclaredNone {
                Text("Check: declared none")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(attempt.checkRuns) { run in
                CheckRunRow(run: run)
            }
        }
    }
}

private struct RoundRow: View {
    let number: Int
    let round: CardDetail.Round

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Round \(number) \u{00B7} \(round.lens.rawValue) \u{00B7} \(round.verdict)")
                .font(.callout.weight(.semibold))
            if let commit = round.judgedCommit {
                Text("judged \(commit)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            // A failed Check's Round carries the Check's output too; its Check run below shows it once in
            // full, so only a review Round's requested changes are shown here.
            if round.lens == .review, let changes = round.requestedChanges, !changes.isEmpty {
                RecordedText(text: changes)
            }
        }
    }
}

private struct CheckRunRow: View {
    let run: CardDetail.CheckRun

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Check \u{00B7} \(run.result.rawValue)\(exitStatus)")
                .font(.callout.weight(.semibold))
                .accessibilityIdentifier("card-detail-check-\(run.id)")
            Text(run.occurredAt.formatted(date: .abbreviated, time: .standard))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let output = run.output, !output.isEmpty {
                RecordedText(text: output)
            }
        }
    }

    private var exitStatus: String {
        run.exitStatus.map { " \u{00B7} exit \($0)" } ?? ""
    }
}

/// Recorded text — a Check's output or a reviewer's requested changes — shown verbatim, scrolling in
/// place rather than stretching the Inspector.
private struct RecordedText: View {
    let text: String

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text)
                .font(.caption.monospaced())
                .fixedSize()
                .padding(8)
        }
        .frame(maxHeight: 200)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
    }
}

/// A labelled value. The identifier goes on the value, not the row: a modifier on a `GridRow` would
/// make the grid lay it out as one cell spanning every column.
private func fact(_ label: LocalizedStringKey, _ value: String, identifier: String? = nil) -> some View {
    GridRow {
        Text(label)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
        Text(value)
            .accessibilityIdentifier(identifier ?? "")
    }
}
