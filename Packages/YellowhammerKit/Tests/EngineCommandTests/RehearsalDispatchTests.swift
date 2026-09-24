import Domain
@testable import Engine
import Foundation
import Repositories
import Testing

// P15.3: a Card-scoped fixture (`byCard`) answers before a by-pass fixture (`byPass`), before the
// default script; a selection fixture's `selected` answer honours the Operator's named Feature and,
// for `selectionSelectedAdopting`, synthesizes its adoptions from the request; a worker/reviewer
// fixture's placeholder commit is answered with the request's Worktree's real HEAD.

private let route = Route(cli: "claude", model: "opus", effort: "high")!

private func cardInstruction(issueID: String, pass: RunPass = .worker, worktreePath: String) -> AgentInstruction {
    let repo = Repo(name: "fixture-backend", path: "/repos/fixture-backend", role: .backend)
    return .card(Instruction(
        pass: pass,
        card: InstructionCard(key: issueID, title: "Card", description: "Fixture Card."),
        brief: ArchitecturalBrief(prose: "Approach.", transcriptions: []),
        definitionOfDone: [],
        repository: InstructionRepository(
            repo: repo, worktreePath: worktreePath, featureBranch: "feature/\(issueID)", check: .none
        ),
        route: route,
        payloads: .none,
        resultFilePath: "\(worktreePath)/.yellowhammer/result.json"
    ))
}

private func authoringRequest(
    issueID: String = "authoring", pass: RunPass, namedFeature: FeatureName? = nil,
    adoptionCandidates: [AdoptionCandidate] = []
) -> AgentDispatchRequest {
    AgentDispatchRequest(
        runID: RunID(), issueID: issueID, attemptID: 1, route: route, pass: pass,
        instruction: .authoring(AuthoringInstruction(
            pass: pass, route: route, specificationSource: .specSource(SpecSource(path: "/repos/spec")),
            specificationMainline: nil, repos: [], mainlines: ResolvedMainlines(), namedFeature: namedFeature,
            adoptionCandidates: adoptionCandidates, selectedFeature: nil, resultFilePath: ""
        )),
        worktreePath: "/repos/spec"
    )
}

private func cardRequest(
    issueID: String, pass: RunPass = .worker, worktreePath: String = "/repos/fixture-backend"
) -> AgentDispatchRequest {
    AgentDispatchRequest(
        runID: RunID(), issueID: issueID, attemptID: 1, route: route, pass: pass,
        instruction: cardInstruction(issueID: issueID, pass: pass, worktreePath: worktreePath),
        worktreePath: worktreePath
    )
}

@Suite("RehearsalDispatch: a Card-scoped fixture, and requests honoured (P15.3)")
struct RehearsalDispatchScriptTests {
    @Test("A Card-scoped fixture answers only its own Card; every other Card falls to the by-pass fixture")
    func cardScopedFixtureAnswersOnlyItsOwnCard() async throws {
        let dispatch = RehearsalDispatch(script: RehearsalScript(
            byPass: [.worker: .workerCompleted],
            byCard: [CardPass(issueID: "BACK-1", pass: .worker): .workerQuestion]
        ))

        let scoped = try await dispatch.dispatch(cardRequest(issueID: "BACK-1"))
        let unscoped = try await dispatch.dispatch(cardRequest(issueID: "BACK-2"))

        guard case .completed(.worker(let scopedResult)) = scoped.outcome else {
            Issue.record("expected a completed worker result")
            return
        }
        guard case .question = scopedResult.outcome else {
            Issue.record("expected the Card-scoped fixture (workerQuestion) to answer BACK-1")
            return
        }
        guard case .completed(.worker(let unscopedResult)) = unscoped.outcome else {
            Issue.record("expected a completed worker result")
            return
        }
        guard case .completed = unscopedResult.outcome else {
            Issue.record("expected the by-pass fixture (workerCompleted) to answer BACK-2")
            return
        }
    }

    @Test("byCard takes priority over byPass for the same Card and pass")
    func byCardTakesPriorityOverByPass() async throws {
        let dispatch = RehearsalDispatch(script: RehearsalScript(
            byPass: [.worker: .workerFailed],
            byCard: [CardPass(issueID: "BACK-1", pass: .worker): .workerCompleted]
        ))

        let report = try await dispatch.dispatch(cardRequest(issueID: "BACK-1"))

        guard case .completed(.worker(let result)) = report.outcome, case .completed = result.outcome else {
            Issue.record("expected byCard's workerCompleted to win over byPass's workerFailed")
            return
        }
    }

    @Test("A selected fixture answers with the Operator's named Feature, not its own")
    func selectedFixtureHonoursNamedFeature() async throws {
        let dispatch = RehearsalDispatch()
        let named = try #require(FeatureName(rawValue: "Operator Named Feature"))

        let report = try await dispatch.dispatch(authoringRequest(pass: .selection, namedFeature: named))

        guard
            case .completed(.selection(let result)) = report.outcome,
            case .selected(let selected) = result.outcome
        else {
            Issue.record("expected a selected outcome")
            return
        }
        #expect(selected.name == named)
    }

    @Test("Without a named Feature, a selected fixture keeps its own name")
    func selectedFixtureKeepsOwnNameWithoutOverride() async throws {
        let dispatch = RehearsalDispatch()

        let report = try await dispatch.dispatch(authoringRequest(pass: .selection))

        guard
            case .completed(.selection(let result)) = report.outcome,
            case .selected(let selected) = result.outcome
        else {
            Issue.record("expected a selected outcome")
            return
        }
        #expect(selected.name.rawValue == "Fixture Feature: rehearsal selection")
    }

    @Test("selectionSelectedAdopting synthesizes adopted_card_issue_ids from the request's adoption candidates")
    func selectionSelectedAdoptingSynthesizesAdoptions() async throws {
        let dispatch = RehearsalDispatch(script: [.selection: .selectionSelectedAdopting])
        let candidates = [
            AdoptionCandidate(issueID: "BACK-1", repository: "fixture-backend"),
            AdoptionCandidate(issueID: "WEB-1", repository: "fixture-web")
        ]

        let report = try await dispatch.dispatch(authoringRequest(pass: .selection, adoptionCandidates: candidates))

        guard
            case .completed(.selection(let result)) = report.outcome,
            case .selected(let selected) = result.outcome
        else {
            Issue.record("expected a selected outcome")
            return
        }
        #expect(selected.adoptedCardIssueIDs == ["BACK-1", "WEB-1"])
    }

    @Test("A worker completed fixture, dispatched against a real git Worktree, answers with its HEAD")
    func workerCompletedAnswersWithRealWorktreeHead() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appending(component: "yh-rehearsal-dispatch-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temp) }
        let git = GitRunner()
        let head = try await initReconcilerGitRepo(at: temp, git: git)
        let dispatch = RehearsalDispatch()

        let report = try await dispatch.dispatch(
            cardRequest(issueID: "BACK-1", pass: .worker, worktreePath: temp.path(percentEncoded: false))
        )

        guard case .completed(.worker(let result)) = report.outcome, case .completed(let commit, _) = result.outcome
        else {
            Issue.record("expected a completed worker result")
            return
        }
        #expect(commit == head)
        #expect(commit != "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678")
    }

    @Test("A worker completed fixture, dispatched against a plain directory, keeps the fixture's own commit")
    func workerCompletedFallsBackToFixtureCommitWithoutAGitRepo() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appending(component: "yh-rehearsal-dispatch-plain-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let dispatch = RehearsalDispatch()

        let report = try await dispatch.dispatch(
            cardRequest(issueID: "BACK-1", pass: .worker, worktreePath: temp.path(percentEncoded: false))
        )

        guard case .completed(.worker(let result)) = report.outcome, case .completed(let commit, _) = result.outcome
        else {
            Issue.record("expected a completed worker result")
            return
        }
        #expect(commit == "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678")
    }

    @Test("A reviewer approved fixture answers with the Worktree's real HEAD too")
    func reviewerApprovedAnswersWithRealWorktreeHead() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appending(component: "yh-rehearsal-dispatch-reviewer-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temp) }
        let git = GitRunner()
        let head = try await initReconcilerGitRepo(at: temp, git: git)
        let dispatch = RehearsalDispatch()

        let report = try await dispatch.dispatch(
            cardRequest(issueID: "BACK-1", pass: .reviewer, worktreePath: temp.path(percentEncoded: false))
        )

        guard
            case .completed(.reviewer(let result)) = report.outcome,
            case .approved(let judgedCommit, _) = result.outcome
        else {
            Issue.record("expected an approved reviewer result")
            return
        }
        #expect(judgedCommit == head)
    }
}
