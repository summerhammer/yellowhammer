import Domain
import Foundation
import Repositories
import Synchronization

/// Which Card a Card-scoped rehearsal fixture answers (P15.3): the Card's board issue id — carried on
/// ``AgentDispatchRequest/issueID``, which for a Card pass is the Journal's `card.issue_id` — and the pass.
public struct CardPass: Hashable, Sendable {
    public let issueID: String
    public let pass: RunPass

    public init(issueID: String, pass: RunPass) {
        self.issueID = issueID
        self.pass = pass
    }
}

/// A rehearsal Night's whole fixture script (P15.3): `byPass` answers every Card's given pass the same
/// way (`--result-fixture <pass>=<fixture>`), `byCard` answers one named Card's given pass
/// (`--result-fixture <pass>@<card issue id>=<fixture>`), which takes priority when both name the same
/// Card and pass. `ExpressibleByDictionaryLiteral` lets a plain `[.worker: .workerQuestion]` literal
/// stand in wherever only `byPass` is needed, as it did before this type existed.
public struct RehearsalScript: Equatable, Sendable {
    public let byPass: [RunPass: RehearsalResultFixture]
    public let byCard: [CardPass: RehearsalResultFixture]

    public init(byPass: [RunPass: RehearsalResultFixture] = [:], byCard: [CardPass: RehearsalResultFixture] = [:]) {
        self.byPass = byPass
        self.byCard = byCard
    }

    public var isEmpty: Bool { byPass.isEmpty && byCard.isEmpty }

    /// No fixtures scripted: every pass answers from ``RehearsalDispatch/defaultScript``. Spelled out as
    /// a name, not `RehearsalScript()`, because that zero-argument call is ambiguous with the
    /// `ExpressibleByDictionaryLiteral` initializer below.
    public static let empty = RehearsalScript(byPass: [:], byCard: [:])
}

extension RehearsalScript: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (RunPass, RehearsalResultFixture)...) {
        self.byPass = Dictionary(uniqueKeysWithValues: elements)
        self.byCard = [:]
    }
}

/// The Dispatch seam for a Rehearsal Night: it never spawns anything (a rehearsal Night never dispatches
/// an agent CLI), and answers each pass from the result files shipped with the engine. The default script
/// is a clean run — architect plans, worker completes, reviewer approves; the author Act's selection selects
/// one Feature and its breakdown drafts one Card — and a test drives a failure by
/// scripting another fixture for a pass, or one Card's pass alone through ``RehearsalScript/byCard``.
/// Selection and breakdown fixtures are answered with the Project's own repository names and spec story
/// citations (``RehearsalFixtureMapping``, #440), so a rehearsal Night on a real Project authors Cards
/// instead of halting; the fixtures' bytes are untouched and a Project that has the fixture names gets them.
public final class RehearsalDispatch: AgentDispatch, Sendable {
    public static let defaultScript: [RunPass: RehearsalResultFixture] = [
        .architect: .architectPlanned,
        .worker: .workerCompleted,
        .reviewer: .reviewerApproved,
        .selection: .selectionSelected,
        .breakdown: .breakdownDrafted,
        .verifier: .verifierReported
    ]

    private let script: RehearsalScript
    private let requests = Mutex<[AgentDispatchRequest]>([])

    /// `script.byPass` overrides the default fixture for the passes it names; `script.byCard` overrides
    /// both for the one Card and pass it names.
    public init(script: RehearsalScript = RehearsalScript.empty) {
        self.script = RehearsalScript(
            byPass: Self.defaultScript.merging(script.byPass) { _, scripted in scripted },
            byCard: script.byCard
        )
    }

    /// A rehearsal Night never dispatches an agent CLI, so no prompt is ever written.
    public var recordsPrompts: Bool { false }

    /// Every request answered so far, in order.
    public var answered: [AgentDispatchRequest] { requests.withLock { $0 } }

    public func dispatch(_ request: AgentDispatchRequest) async throws -> AgentDispatchReport {
        requests.withLock { $0.append(request) }
        let workCardKey = CardPass(issueID: request.issueID, pass: request.pass)
        guard let fixture = script.byCard[workCardKey] ?? script.byPass[request.pass] else {
            preconditionFailure("RehearsalDispatch has no fixture for pass \(request.pass)")
        }
        let outcome: RunOutcome
        if fixture == .verifierReported {
            outcome = Self.verifierOutcome(for: request)
        } else if fixture.pass == .selection {
            outcome = Self.selectionOutcome(fixture: fixture, for: request)
        } else if fixture.pass == .breakdown {
            outcome = await Self.breakdownOutcome(fixture: fixture, for: request)
        } else if fixture.pass == .worker || fixture.pass == .reviewer {
            outcome = await Self.commitAdjustedOutcome(fixture.outcome(), worktreePath: request.worktreePath)
        } else {
            outcome = fixture.outcome()
        }
        return AgentDispatchReport(outcome: outcome, origin: .rehearsalFixture(fixture.rawValue))
    }

    /// The `verifier-reported` fixture cannot know the clause ids it will be asked about, so it is
    /// synthesized from the request: every clause its ``VerificationInstruction`` names is reported `met`
    /// under fixed rehearsal copy. It asserts nothing about any code — a rehearsal Night reads none.
    private static func verifierOutcome(for request: AgentDispatchRequest) -> RunOutcome {
        guard case .verification(let instruction) = request.instruction else {
            preconditionFailure("a verifier request carries a verification instruction")
        }
        let clauses = instruction.clauses.map {
            VerifiedClause(
                cid: $0.cid, issueID: $0.issueID, verdict: .met,
                whatWasChecked: "Fixture data: a rehearsal Night reads no code.",
                interpretation: "Fixture data: the clause as written."
            )
        }
        return .completed(.verifier(VerifierResult(outcome: .reported(clauses: clauses))))
    }

    /// A selection fixture's `selected` answer is adjusted to honour the request, the same way
    /// ``verifierOutcome(for:)`` synthesizes from it: the Operator's named Feature (Force authoring,
    /// `yh author --feature <name>`) overrides the fixture's own name — a real selector must honour it,
    /// else selection itself refuses with `namedFeatureIgnored` — and
    /// ``RehearsalResultFixture/selectionSelectedAdopting``'s empty `adopted_card_issue_ids` is
    /// synthesized from the request's adoption candidates (documented on that fixture's own case).
    /// Every other fixture, and every other outcome, is returned untouched.
    private static func selectionOutcome(
        fixture: RehearsalResultFixture, for request: AgentDispatchRequest
    ) -> RunOutcome {
        let outcome = fixture.outcome()
        guard case .authoring(let instruction) = request.instruction else {
            preconditionFailure("a selection request carries an authoring instruction")
        }
        guard case .completed(.selection(let result)) = outcome, case .selected(let selected) = result.outcome else {
            return outcome
        }
        let name = instruction.namedFeature ?? selected.name
        let adoptedCardIssueIDs = fixture == .selectionSelectedAdopting
            ? instruction.adoptionCandidates.map(\.issueID)
            : selected.adoptedCardIssueIDs
        let adjusted = SelectedFeature(
            name: name, reasoning: selected.reasoning, sequence: selected.sequence,
            repositories: selected.repositories, adoptedCardIssueIDs: adoptedCardIssueIDs
        )
        let mapped = RehearsalFixtureMapping(repos: instruction.repos, storyIDs: []).apply(to: adjusted)
        return .completed(.selection(SelectionResult(outcome: .selected(mapped))))
    }

    /// A breakdown fixture's `drafted` answer is re-aimed at the Project (#440), like
    /// ``selectionOutcome(fixture:for:)``: its fixture repository names become the request's own
    /// ``AuthoringInstruction/repos`` (not the selected Feature's repositories, which the engine re-sorts)
    /// and its `fixture-epic/...` citations become story IDs read from the Project's specification
    /// (``specStoryIDs(for:)``). Every other outcome is returned untouched.
    private static func breakdownOutcome(
        fixture: RehearsalResultFixture, for request: AgentDispatchRequest
    ) async -> RunOutcome {
        let outcome = fixture.outcome()
        guard case .authoring(let instruction) = request.instruction else {
            preconditionFailure("a breakdown request carries an authoring instruction")
        }
        guard case .completed(.breakdown(let result)) = outcome, case .drafted(let breakdown) = result.outcome else {
            return outcome
        }
        let mapping = RehearsalFixtureMapping(
            repos: instruction.repos, storyIDs: await specStoryIDs(for: instruction)
        )
        return .completed(.breakdown(BreakdownResult(outcome: .drafted(mapping.apply(to: breakdown)))))
    }

    /// The `<epic>/<story>` IDs of the Project's specification, sorted: `git ls-tree` of
    /// `docs/requirements/epics` at the specification mainline's commit (HEAD when none was resolved),
    /// keeping only `docs/requirements/epics/<epic>/stories/<story>.md`. Empty on any git failure, which
    /// leaves the fixture's citations untouched.
    private static func specStoryIDs(for instruction: AuthoringInstruction) async -> [String] {
        let path = (instruction.specificationSource.path as NSString).expandingTildeInPath
        let commit = instruction.specificationMainline?.commit ?? "HEAD"
        let result = await GitRunner().run(
            ["ls-tree", "-r", "--name-only", commit, "--", "docs/requirements/epics"], workingDirectory: path
        )
        guard result.isSuccess else { return [] }
        let ids = result.stdout.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let parts = line.split(separator: "/", omittingEmptySubsequences: false)
            guard
                parts.count == 6, parts[0] == "docs", parts[1] == "requirements", parts[2] == "epics",
                parts[4] == "stories", parts[5].hasSuffix(".md"), parts[5].count > 3, !parts[3].isEmpty
            else { return nil }
            return "\(parts[3])/\(parts[5].dropLast(3))"
        }
        return Array(Set(ids)).sorted()
    }

    /// A worker `completed` or reviewer `approved`/`changesRequested` fixture reports a commit it made
    /// up — `worker-completed.json`'s `a1b2c3d4...` is a placeholder, not a real SHA. A rehearsal Night
    /// never commits, so recording that placeholder as the Worktree's last known-good commit
    /// (`CardRunEnd.approved`, `JournalStore.recordWorktreeKnownGood`) leaves a later reset-to-known-good
    /// (a retry or Block in the same lane) failing on a commit that does not exist. Synthesized from the
    /// request the same way ``verifierOutcome(for:)`` and ``selectionOutcome(fixture:for:)`` are: answered
    /// with the actual HEAD of the request's Worktree, falling back to the fixture's own value only when
    /// HEAD cannot be resolved (a test's plain directory, not a git work tree).
    private static func commitAdjustedOutcome(_ outcome: RunOutcome, worktreePath: String) async -> RunOutcome {
        guard case .completed(let result) = outcome else { return outcome }
        switch result {
        case .worker(let workerResult):
            guard case .completed(let commit, let summary) = workerResult.outcome else { return outcome }
            let head = await Self.resolvedHead(at: worktreePath) ?? commit
            return .completed(.worker(WorkerResult(
                outcome: .completed(commit: head, summary: summary),
                authoringInvariantViolation: workerResult.authoringInvariantViolation
            )))
        case .reviewer(let reviewerResult):
            switch reviewerResult.outcome {
            case .approved(let judgedCommit, let summary):
                let head = await Self.resolvedHead(at: worktreePath) ?? judgedCommit
                return .completed(.reviewer(ReviewerResult(outcome: .approved(judgedCommit: head, summary: summary))))
            case .changesRequested(let judgedCommit, let summary, let requestedChanges):
                let head = await Self.resolvedHead(at: worktreePath) ?? judgedCommit
                return .completed(.reviewer(ReviewerResult(outcome: .changesRequested(
                    judgedCommit: head, summary: summary, requestedChanges: requestedChanges
                ))))
            }
        default:
            return outcome
        }
    }

    /// `worktreePath`'s actual HEAD, or nil when it cannot be resolved — not a git work tree, or `git`
    /// itself is unavailable. `git -C <path> rev-parse --verify HEAD^{commit}`, via the same
    /// ``Repositories/GitRunner`` the Engine already runs every other git command through.
    private static func resolvedHead(at worktreePath: String) async -> String? {
        let result = await GitRunner().run(["rev-parse", "--verify", "HEAD^{commit}"], workingDirectory: worktreePath)
        guard result.isSuccess else { return nil }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
