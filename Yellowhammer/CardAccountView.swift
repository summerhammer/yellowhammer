import AppKit
import Domain
import Journal
import SwiftUI

/// The read-only Journal account behind a Card (P14.5; G-6): pick one of the Project's Cards and read
/// what its Journal recorded — Attempts, Rounds, routes and Check output. Reading only: nothing here
/// transitions, retries or triages a Card. Every decision about a Card is made in Linear.
struct CardAccountView: View {
    @State private var model: CardAccountModel

    init(project: ProjectID) {
        _model = State(initialValue: CardAccountModel(project: project))
    }

    var body: some View {
        content
            .toolbar {
                ToolbarItem {
                    Button("Reload", systemImage: "arrow.clockwise") { model.load() }
                        .accessibilityIdentifier("card-account-reload")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.load()
            }
    }

    @ViewBuilder private var content: some View {
        if let cards = model.cards {
            HSplitView {
                cardList(cards)
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
                detail
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            unavailable
        }
    }

    private func cardList(_ cards: [CardRecord]) -> some View {
        List(selection: Binding(get: { model.selectedIssueID }, set: { model.select($0) })) {
            ForEach(cards, id: \.issueID) { card in
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.issueID)
                    Text(card.repository)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(card.issueID)
                .accessibilityIdentifier("card-account-row-\(card.issueID)")
            }
        }
        .overlay {
            if cards.isEmpty {
                Text("The Journal has no Cards yet.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("card-account-no-cards")
            }
        }
        .accessibilityIdentifier("card-account-list")
    }

    @ViewBuilder private var detail: some View {
        if let account = model.account {
            ScrollView {
                CardAccountDetail(account: account)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Pick a Card to read its account.")
                .foregroundStyle(.secondary)
        }
    }

    private var unavailable: some View {
        VStack(spacing: 8) {
            if model.journalMissing {
                Text("This Project has no Journal yet.")
                    .accessibilityIdentifier("card-account-journal-missing")
                Text("A Journal is written by the first Act that runs for this Project.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Yellowhammer can\u{2019}t read this Project\u{2019}s Journal.")
                Text(model.failure ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("card-account-failure")
            }
        }
        .multilineTextAlignment(.center)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One Card's account, laid out as the Journal recorded it: the Card, the routes, then each Attempt
/// with its Rounds and Check runs in order.
private struct CardAccountDetail: View {
    let account: CardAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardSection
            routesSection
            if account.history.attempts.isEmpty {
                Text("No Attempt has been recorded for this Card.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(account.history.attempts.enumerated()), id: \.element.id) { index, attempt in
                AttemptSection(
                    number: index + 1, attempt: attempt, checkRuns: account.checkRuns(attemptID: attempt.id)
                )
            }
        }
        .textSelection(.enabled)
    }

    private var card: CardRecord { account.card }

    private var cardSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.issueID)
                .font(.title2)
                .accessibilityIdentifier("card-account-issue")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                row("Repo", card.repository)
                row("Kind", card.kind)
                row("State", stateText)
                    .accessibilityIdentifier("card-account-state")
                if let blockReason = card.blockReason {
                    row("Block reason", blockReason)
                }
                row("Budget epoch", "\(card.budgetEpoch)")
                row("Attempts", "\(account.history.attemptCount)")
                    .accessibilityIdentifier("card-account-attempt-count")
                row("Rounds", "\(account.history.roundCount)")
                    .accessibilityIdentifier("card-account-round-count")
            }
        }
    }

    private var stateText: String {
        guard let reason = card.waitingReason else { return card.state.rawValue }
        return "\(card.state.rawValue) (\(reason.rawValue))"
    }

    private var routesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Routes").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                row("Tried", routeList(account.history.routesTried))
                    .accessibilityIdentifier("card-account-routes-tried")
                row("Excluded", routeList(account.history.excludedRoutes))
            }
        }
    }

    private func routeList(_ routes: [Route]) -> String {
        routes.isEmpty ? "none" : routes.map(\.display).joined(separator: ", ")
    }
}

/// One Attempt: its Route and how it ended, then its Rounds and the Check runs over its work.
private struct AttemptSection: View {
    let number: Int
    let attempt: AttemptRecord
    let checkRuns: [CheckRunRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Attempt \(number) \u{2014} \(attempt.route.display)")
                .font(.headline)
                .accessibilityIdentifier("card-account-attempt-\(number)")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                if let source = attempt.routeSource {
                    row("Route source", source)
                }
                if let pin = attempt.overridePin {
                    row("Override", pin)
                }
                row("Started", attempt.startedAt.formatted(date: .abbreviated, time: .standard))
                row("Ended", attempt.endedAt?.formatted(date: .abbreviated, time: .standard) ?? "not ended")
                if let result = attempt.result {
                    row("Result", result)
                }
                if let classification = attempt.classification {
                    row("Classification", classification)
                }
                if let consumedHow = attempt.consumedHow {
                    row("Consumed", consumedHow)
                }
                if let preservedRef = attempt.preservedRef {
                    let preserved = [preservedRef, attempt.preservedCommit].compactMap(\.self)
                    row("Preserved", preserved.joined(separator: " @ "))
                }
            }
            ForEach(Array(attempt.rounds.enumerated()), id: \.element.id) { index, round in
                RoundRow(number: index + 1, round: round)
            }
            if attempt.checkDeclaredNone {
                Text("Check: declared none")
                    .foregroundStyle(.secondary)
            }
            ForEach(checkRuns, id: \.eventID) { run in
                CheckRunRow(run: run)
            }
        }
    }
}

private struct RoundRow: View {
    let number: Int
    let round: RoundRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Round \(number) \u{00B7} \(round.lens.rawValue) \u{00B7} \(round.verdict)")
                .font(.subheadline.weight(.semibold))
            if let commit = round.judgedCommit {
                Text("judged \(commit)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            // A failed Check's Round carries the Check's output here too; the Check run below shows it
            // once in full, so only a review Round's requested changes are repeated.
            if round.lens == .review, let changes = round.requestedChanges, !changes.isEmpty {
                OutputBlock(text: changes)
            }
        }
        .padding(.leading, 8)
    }
}

private struct CheckRunRow: View {
    let run: CheckRunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Check \u{00B7} \(run.result.rawValue)\(exitStatus)")
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("card-account-check-\(run.eventID)")
            Text(run.occurredAt.formatted(date: .abbreviated, time: .standard))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let output = run.output, !output.isEmpty {
                OutputBlock(text: output)
            }
        }
        .padding(.leading, 8)
    }

    private var exitStatus: String {
        run.exitStatus.map { " \u{00B7} exit \($0)" } ?? ""
    }
}

/// Recorded text — a Check's output or a reviewer's requested changes — shown verbatim.
private struct OutputBlock: View {
    let text: String

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text)
                .font(.caption.monospaced())
                .fixedSize()
                .padding(8)
        }
        .frame(maxHeight: 240)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

private func row(_ label: String, _ value: String) -> some View {
    GridRow {
        Text(label).foregroundStyle(.secondary)
        Text(value)
    }
}

private extension Route {
    var display: String { "\(cli)/\(model)/\(effort)" }
}
