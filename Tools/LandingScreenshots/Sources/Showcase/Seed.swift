import Config
import Domain
import Foundation

@testable import Journal

// The cast of the showcase Night, and the author Act run both configurations open with.

struct ShowcaseCard {
    let number: Int
    let title: String
    let repo: String
}

public enum Showcase {
    static let apiRepo = "orbit-api"
    static let webRepo = "orbit-web"
    static let iosRepo = "orbit-ios"

    /// In authored order, which is also the order the Journal lists them within a Repo.
    static let cards = [
        ShowcaseCard(number: 213, title: "Add saved_search table and API", repo: apiRepo),
        ShowcaseCard(number: 214, title: "Saved searches endpoint pagination", repo: apiRepo),
        ShowcaseCard(number: 215, title: "Saved search sharing permissions", repo: apiRepo),
        ShowcaseCard(number: 216, title: "Saved searches list in web", repo: webRepo),
        ShowcaseCard(number: 217, title: "Save-search dialog in web", repo: webRepo),
        ShowcaseCard(number: 218, title: "Saved searches screen in iOS", repo: iosRepo),
        ShowcaseCard(number: 219, title: "Pin saved searches to the iOS tab bar", repo: iosRepo)
    ]

    /// The id of ORB-214's open Attempt in `working/`, which the capture side opens as `now-attempt-5`.
    public static let retriedAttemptID = "5"

    static let featureName = "Saved searches"
    static let featureBranch = "yh/orb-212-saved-searches"

    static func projectID() throws -> ProjectID {
        try required(ProjectID(rawValue: "orbit"))
    }

    /// A Linear issue's UUID (version 4); `ORB-n` is the identifier a person reads, recorded beside it.
    static func issueID(_ number: Int) -> String {
        "0b17a1c0-0000-4000-8000-000000000\(number)"
    }

    static func issueURL(_ number: Int) -> String {
        "https://linear.app/orbit/issue/ORB-\(number)"
    }

    static func route(_ label: String) throws -> Route {
        try required(Route(label: label))
    }

    static func checkCommand(for repo: String) -> String {
        switch repo {
        case apiRepo: "swift test"
        case webRepo: "pnpm test"
        default: "make test"
        }
    }
}

struct ShowcaseNight {
    let nightID: Int64
    let featureID: Int64
    let cycleID: Int64
}

/// The author Act run, 22:00 to 22:04: it opens the Night, opens the Night Card, selects "Saved searches" and
/// authors its Cycle of seven Work Cards.
func seedAuthorRun(_ journal: JournalStore, clock: ShowcaseClock) throws -> ShowcaseNight {
    let runID = RunID()
    let opened = clock.night(22, 0)
    _ = try journal.claimActLease(act: .author, runID: runID, mode: .real, now: opened)
    let night = try journal.openNight(
        nightStart: clock.nightStart(), mode: .real, act: .author, runID: runID, now: opened
    ).night
    let run = ShowcaseRun(journal: journal, act: .author, runID: runID, nightID: night.id)
    try run.record(.actStarted, at: clock.night(22, 0, 1))
    try run.record(.linearReached, at: clock.night(22, 0, 5))
    try run.beat(clock.night(22, 0, 20))
    try journal.recordNightCard(
        id: night.id, issueID: Showcase.issueID(200), act: .author, runID: runID, now: clock.night(22, 0, 20)
    )
    try recordSelection(run, clock: clock)
    let created = try createFeature(journal, clock: clock)
    try run.record(
        .featureAuthored(
            FeatureAuthoredPayload(
                name: Showcase.featureName, groupKey: "saved-searches", featureIssueID: Showcase.issueID(212),
                cycleID: created.cycleID, cardCount: Showcase.cards.count, adoptedCount: 0
            )
        ),
        at: clock.night(22, 3, 30)
    )
    try recordLinksAndTitles(run, clock: clock)
    try run.finish(at: clock.night(22, 4))
    return ShowcaseNight(nightID: night.id, featureID: created.featureID, cycleID: created.cycleID)
}

private func recordSelection(_ run: ShowcaseRun, clock: ShowcaseClock) throws {
    let selection = FeatureSelectedPayload(
        name: Showcase.featureName,
        reasoning: "Next in the spec, and no open Feature depends on it.",
        precededBy: nil, followedBy: nil, seam: nil,
        repositories: [Showcase.apiRepo, Showcase.webRepo, Showcase.iosRepo],
        adoptedCardIssueIDs: [], unadoptedCardIssueIDs: []
    )
    try run.record(
        .authoringDispatched(pass: .selection, route: "claude/opus/high", ordinal: 1, fixture: nil),
        at: clock.night(22, 0, 40)
    )
    try run.record(.featureSelected(selection), at: clock.night(22, 1, 30))
    try run.record(
        .authoringDispatched(pass: .breakdown, route: "claude/opus/high", ordinal: 1, fixture: nil),
        at: clock.night(22, 1, 40)
    )
}

/// The Feature row, its Cycle and the seven Work Cards, all Todo, created as the author Act accepts the plan.
private func createFeature(
    _ journal: JournalStore, clock: ShowcaseClock
) throws -> (featureID: Int64, cycleID: Int64) {
    let createdAt = JournalStore.timestamp(clock.night(22, 3, 20))
    return try journal.write { database in
        try database.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: [Showcase.issueID(212), "selected", createdAt]
        )
        let featureID: Int64 = database.lastInsertedRowID
        try database.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)", arguments: [featureID, createdAt]
        )
        let cycleID: Int64 = database.lastInsertedRowID
        for (order, card) in Showcase.cards.enumerated() {
            try database.execute(
                sql: """
                INSERT INTO card (
                    cycle_id, issue_id, repository, kind, authored_order, state, block_reason, budget_epoch,
                    created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    cycleID, Showcase.issueID(card.number), card.repo, "card", order + 1,
                    CardState.todo.rawValue, nil, 0, createdAt
                ]
            )
        }
        return (featureID, cycleID)
    }
}

/// The Delta Read's view of the board: every issue's identifier and link, and the Work Cards' titles.
private func recordLinksAndTitles(_ run: ShowcaseRun, clock: ShowcaseClock) throws {
    let time = clock.night(22, 3, 40)
    try run.beat(time)
    for number in [200, 212] + Showcase.cards.map(\.number) {
        try run.journal.recordIssueLink(
            issueID: Showcase.issueID(number), key: "ORB-\(number)", url: Showcase.issueURL(number),
            runID: run.runID, now: time
        )
    }
    for card in Showcase.cards {
        try run.journal.updateCardTitle(
            cardID: run.cardID(card.number), title: card.title, runID: run.runID, now: time
        )
    }
}

// MARK: - One Card's run

extension ShowcaseRun {
    func cardID(_ number: Int) throws -> Int64 {
        try required(try journal.card(issueID: Showcase.issueID(number))).id
    }

    func openAttemptID(_ number: Int) throws -> Int64 {
        try required(try journal.attemptHistory(cardID: cardID(number)).openAttempt).id
    }

    func step(_ number: Int, _ step: CardRunStep, _ detail: String?, at time: Date) throws {
        let event = JournalEvent.cardRunStep(
            cardID: try cardID(number), issueID: Showcase.issueID(number), step: step, detail: detail
        )
        try record(event, at: time)
    }

    /// The Card goes In Progress, claims its lease and starts an Attempt on `route`.
    func startAttempt(_ number: Int, on route: Route, at time: Date) throws {
        try beat(time)
        try journal.transitionCard(
            cardID: cardID(number), to: .inProgress, runID: runID, act: act, nightID: nightID, now: time
        )
        try step(number, .leaseClaimed, nil, at: time + 1)
        try beat(time + 2)
        let attempt = try journal.recordAttempt(
            cardID: cardID(number), route: route, routeSource: "entry", runID: runID, act: act, nightID: nightID,
            now: time + 2
        )
        try step(number, .attemptStarted, "attempt \(attempt.id) on \(route)", at: time + 3)
        try capturePrompt(number, attempt: attempt.id, route: route, at: time + 3)
    }

    /// The worker pass's prompt, captured before launch, as the Night inspector's Prompts list reads it.
    private func capturePrompt(_ number: Int, attempt: Int64, route: Route, at time: Date) throws {
        let configurationDirectory = journal.fileURL.deletingLastPathComponent().deletingLastPathComponent()
        let store = DispatchPromptStore(
            rootDirectory: DispatchPromptStore.rootDirectory(configurationDirectory: configurationDirectory),
            now: { time }
        )
        let card = try cardID(number)
        let recordID = "showcase-\(attempt)-worker"
        let provenance = DispatchProvenance(
            recordID: recordID, family: .worker, projectID: journal.projectID.rawValue,
            featureIssueID: Showcase.issueID(212), workCardIssueID: Showcase.issueID(number), cardID: card,
            attemptID: attempt, round: 1, routeTry: 1
        )
        let title = try required(Showcase.cards.first { $0.number == number }).title
        let prompt = DispatchPromptRecord(
            id: recordID, provenance: provenance, route: route.description, pass: .worker, dispatchedAt: time,
            defaultVersion: 1, projectInstructions: .absent, session: .new,
            instruction: "Implement ORB-\(number): \(title). Keep the change inside the Card's Repo.",
            outputSchema: nil, launch: .launched
        )
        guard case .recorded = store.capture(prompt) else {
            throw ShowcaseError(description: "Could not capture attempt \(attempt)'s prompt")
        }
        try record(
            .promptCaptureRequested(
                recordID: recordID, pass: .worker, cardID: card, issueID: Showcase.issueID(number),
                attemptID: attempt, round: 1, ordinal: 1
            ),
            at: time
        )
    }

    /// The worker finishes and the engine-run Check passes.
    func workAndCheck(_ number: Int, at time: Date) throws {
        let attempt = try openAttemptID(number)
        let repo = try required(Showcase.cards.first { $0.number == number }).repo
        try step(number, .worker, "completed", at: time)
        try record(
            .checkRan(
                cardID: cardID(number), issueID: Showcase.issueID(number), attemptID: attempt, result: .passed,
                exitStatus: 0, output: "All tests passed", judgedCommit: "c0ffee\(number)",
                command: Showcase.checkCommand(for: repo)
            ),
            at: time + 20
        )
        try step(number, .check, "passed", at: time + 21)
    }

    /// The reviewer approves: the Attempt succeeds, the Card is Done and releases its lease.
    func approve(_ number: Int, at time: Date) throws {
        let attempt = try openAttemptID(number)
        try step(number, .reviewer, "approved", at: time)
        try beat(time + 1)
        try journal.endAttempt(
            attemptID: attempt, ending: .success, runID: runID, act: act, nightID: nightID, now: time + 1
        )
        try beat(time + 2)
        try journal.transitionCard(
            cardID: cardID(number), to: .done, runID: runID, act: act, nightID: nightID, now: time + 2
        )
        try step(number, .leaseReleased, nil, at: time + 3)
    }

    /// The reviewer asks for changes: a further Round of the same Attempt.
    func requestChanges(_ number: Int, note: String, at time: Date) throws {
        let attempt = try openAttemptID(number)
        try step(number, .reviewer, "changes requested", at: time)
        try beat(time + 1)
        try journal.recordRound(
            attemptID: attempt, lens: .review, verdict: "changes requested", requestedChanges: note,
            judgedCommit: "c0ffee\(number)", runID: runID, now: time + 1
        )
    }

    /// The Route fails hard: the Attempt ends, consumed, and the Route is excluded for this Card.
    func failOnUsageLimit(_ number: Int, at time: Date) throws {
        let attempt = try openAttemptID(number)
        let reason = "usage limit reached; resets in 3 hours"
        try step(number, .worker, "failed \u{2014} \(reason)", at: time)
        try beat(time + 1)
        try journal.endAttempt(
            attemptID: attempt, ending: .hardFailure(.reported(reason: reason)), runID: runID, act: act,
            nightID: nightID, now: time + 1
        )
    }
}

extension ShowcaseScript {
    /// A Card whose Attempt runs `start` to `end` and is approved.
    mutating func card(_ number: Int, on route: Route, from start: Date, to end: Date) {
        let checked = start.addingTimeInterval(end.timeIntervalSince(start) * 0.7)
        at(start) { try $0.startAttempt(number, on: route, at: start) }
        at(checked) { try $0.workAndCheck(number, at: checked) }
        at(end) { try $0.approve(number, at: end) }
    }
}
