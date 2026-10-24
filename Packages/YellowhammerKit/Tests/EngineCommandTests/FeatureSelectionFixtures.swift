import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Synchronization
import Testing

// roadmap P9.3: fixtures and helpers shared by FeatureSelectionTests.swift and
// FeatureSelectionHaltTests.swift, split out to keep each under the file and type-body length limits.

let featureSelectionNightStart = NightStart(rawValue: "2026-09-20")!

/// A `FeatureSelecting` that always answers the same outcome and records the request it was handed.
final class ScriptedFeatureSelector: FeatureSelecting, Sendable {
    private struct State {
        var request: FeatureSelectionRequest?
        var callCount = 0
    }
    private let state = Mutex(State())
    private let outcomes: [FeatureSelectionOutcome]

    init(outcome: FeatureSelectionOutcome) {
        self.outcomes = [outcome]
    }

    init(outcomes: [FeatureSelectionOutcome]) {
        self.outcomes = outcomes
    }

    var lastRequest: FeatureSelectionRequest? { state.withLock { $0.request } }
    var callCount: Int { state.withLock { $0.callCount } }

    func select(_ request: FeatureSelectionRequest, context: ActContext) async throws -> FeatureSelectionOutcome {
        let index = state.withLock { box -> Int in
            box.request = request
            let current = box.callCount
            box.callCount += 1
            return current
        }
        guard !outcomes.isEmpty else { return .noSelectableFeature }
        return outcomes[min(index, outcomes.count - 1)]
    }
}

/// A `SelectedFeatureAuthoring` that records the validated selection it was handed.
final class ScriptedSelectedFeatureAuthoring: SelectedFeatureAuthoring, Sendable {
    private struct State {
        var selection: SelectedFeature?
        var callCount = 0
        var lastReselectionDepth: Int?
    }
    private let state = Mutex(State())

    var lastSelection: SelectedFeature? { state.withLock { $0.selection } }
    var callCount: Int { state.withLock { $0.callCount } }
    var lastReselectionDepth: Int? { state.withLock { $0.lastReselectionDepth } }

    func author(
        _ selection: SelectedFeature, reselectionDepth: Int, context: ActContext
    ) async throws -> FeatureAuthoringOutcome {
        state.withLock { $0.selection = selection; $0.callCount += 1; $0.lastReselectionDepth = reselectionDepth }
        return .authored
    }

    func resumeUnfinished(_ context: ActContext) async throws -> FeatureAuthoringOutcome? { nil }
}

/// Builds an `ActContext` for calling `FeatureSelection.selectAndAuthor` directly, mirroring
/// `makeGateContext` (PredecessorAncestryGateFixtures.swift) but wired with an Outbox and Board when
/// one is handed, for the halt-routing tests.
func makeSelectionContext(
    _ journal: JournalStore, repositories: ProjectRepositories?, boards: NightCardTestBoards? = nil,
    trigger: ActTrigger = .scheduled, workspace: (any Workspace)? = nil,
    mainlines: ResolvedMainlines = selectionMainlines(), descriptionBudget: DescriptionBudget? = nil
) throws -> (context: ActContext, runID: RunID) {
    let runID = RunID()
    guard case .claimed = try journal.claimActLease(act: .author, runID: runID, mode: .rehearsal) else {
        throw JournalError.actLeaseLost(runID: runID, holder: nil)
    }
    let opening = try journal.openNight(
        nightStart: featureSelectionNightStart, mode: .rehearsal, act: .author, runID: runID
    )
    var outbox: Outbox?
    var actBoard: ActBoard?
    if let boards {
        outbox = Outbox(
            journal: journal, board: boards.writing, runID: runID, act: .author, nightID: opening.night.id
        )
        actBoard = ActBoard(
            reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning,
            descriptionBudget: descriptionBudget
        )
    }
    let context = ActContext(
        act: .author, mode: .rehearsal, trigger: trigger, runID: runID, journal: journal,
        night: opening.night, outbox: outbox, board: actBoard, mainlines: mainlines,
        workspace: workspace, repositories: repositories, featureBases: selectionFeatureBases(mainlines)
    )
    return (context, runID)
}

func selectionRepositories(includeSpecWorkingRepo: Bool = false) -> ProjectRepositories {
    var workingRepos = [
        Repo(name: "backend", path: "/repos/backend", role: .backend),
        Repo(name: "mobile", path: "/repos/mobile", role: .mobile)
    ]
    if includeSpecWorkingRepo {
        workingRepos.append(Repo(name: "spec-repo", path: "/repos/spec-repo", role: .spec))
    }
    // With `includeSpecWorkingRepo`, both a dedicated Spec Source and a role-`spec` working repo are
    // present, so the Project has two specification sources — deliberately invalid, for that test.
    return ProjectRepositories(workingRepos: workingRepos, specSource: SpecSource(path: "/repos/spec"))
}

func selectionMainlines() -> ResolvedMainlines {
    let backend = ResolvedMainline(
        repository: "backend", defaultBranch: "main", ref: "refs/heads/main", commit: String(repeating: "a", count: 40)
    )
    let mobile = ResolvedMainline(
        repository: "mobile", defaultBranch: "main", ref: "refs/heads/main", commit: String(repeating: "b", count: 40)
    )
    let spec = ResolvedMainline(
        repository: "spec_source", defaultBranch: "main", ref: "refs/heads/main",
        commit: String(repeating: "c", count: 40)
    )
    return ResolvedMainlines(workingRepos: ["backend": backend, "mobile": mobile], specSource: spec)
}

/// Mainlines for the named working repositories only, for a Project whose repositories are not the fixture's.
func selectionMainlines(forWorkingRepos names: [String]) -> ResolvedMainlines {
    ResolvedMainlines(workingRepos: Dictionary(uniqueKeysWithValues: names.map {
        ($0, ResolvedMainline(
            repository: $0, defaultBranch: "main", ref: "refs/heads/main", commit: String(repeating: "d", count: 40)
        ))
    }))
}

/// The `feature_base` rows an unstacked selection records: one per working repo, at that repo's mainline.
func selectionFeatureBases(_ mainlines: ResolvedMainlines) -> [FeatureBaseRecord] {
    mainlines.workingRepos.values.sorted { $0.repository < $1.repository }.map {
        FeatureBaseRecord(repository: $0.repository, baseRef: $0.ref, baseCommit: $0.commit)
    }
}

func tableRowCount(_ journal: JournalStore, table: String) throws -> Int {
    try journal.write { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
    }
}

func waitingOnYouStateID(_ boards: NightCardTestBoards) async throws -> BoardObjectID {
    let states = try await boards.provisioning.workflowStates(team: teamID)
    guard let id = states.first(where: { $0.name == "Waiting on You" })?.id else {
        Issue.record("Waiting on You state was not seeded")
        return BoardObjectID(rawValue: "missing")
    }
    return id
}

@discardableResult
func insertFeatureSelectionAdoptionFixture(
    _ journal: JournalStore, closedFeatureIssueID: String
) throws -> (featureID: Int64, cycleID: Int64) {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: [closedFeatureIssueID, "selected", JournalStore.timestamp(Date())]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at, archived_at) VALUES (?, ?, ?)",
            arguments: [featureID, JournalStore.timestamp(Date()), JournalStore.timestamp(Date())]
        )
        return (featureID, db.lastInsertedRowID)
    }
}

/// Inserts a Blocked Card — the state feature selection's adoption candidates are read from
/// (`blockedCardsLeftByClosedFeatures`). A test needing a different state inserts directly.
@discardableResult
func insertFeatureSelectionAdoptionCard(
    _ journal: JournalStore, cycleID: Int64, issueID: String, repository: String, order: Int
) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cycleID, issueID, repository, "card", order, CardState.blocked.rawValue, 0,
                JournalStore.timestamp(Date())
            ]
        )
        return db.lastInsertedRowID
    }
}
