import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// roadmap P9.6 (spec: feature-authoring/author-an-architectural-brief): a Card that needs a contract
// this author Act cannot read is never authored speculatively — split out of AuthoringTranscriptionTests
// to keep each file under the type-body-length limit.

@Suite("Authoring transaction: unreadable contracts halt authoring (P9.6)")
struct AuthoringTranscriptionHaltTests {
    @Test("A contract naming a repository outside the Project halts authoring, naming that repository")
    func contractOutsideProjectHaltsAuthoring() async throws {
        let kind = try authoringKind()
        let breakdown = FeatureBreakdown(
            definitionOfDone: [authoringClause("The Feature is done.")],
            cards: [
                CardDraft(
                    repository: "backend", kind: kind, title: "Backend one", unitOfWork: "Do it",
                    brief: "Approach.",
                    definitionOfDone: [authoringClause("Backend one is done.")],
                    contracts: [ContractDraft(repository: "web", paths: ["a.swift"])]
                )
            ]
        )
        let rig = try await AuthoringRig(drafting: ScriptedBreakdown(breakdown), transcribing: MainlineReader())

        let outcome = try await rig.run(rig.context())

        #expect(outcome == .halted)
        #expect(try tableRowCount(rig.journal, table: "feature") == 0)
        #expect(try tableRowCount(rig.journal, table: "card") == 0)
        #expect(try tableRowCount(rig.journal, table: "architectural_brief") == 0)
        #expect(try tableRowCount(rig.journal, table: "transcription_block") == 0)
        #expect(try tableRowCount(rig.journal, table: "attempt") == 0)
        #expect(try rig.journal.events(ofType: .featureAuthoringAccepted).isEmpty)

        let event = try #require(try rig.journal.events().first { $0.type == .featureAuthoringHalted })
        guard case .featureAuthoringHalted(let name, let kind, let detail) = event.event else {
            Issue.record("expected featureAuthoringHalted")
            return
        }
        #expect(name == "FEAT-1")
        #expect(kind == "contract-unreadable")
        #expect(detail?.contains("web") == true)

        let live = await rig.boards.writing.liveIssues
        let issue = try #require(live.first { $0.title == "FEAT-1" })
        #expect(try await issue.workflowState == waitingOnYouStateID(rig.boards))
        let comments = await rig.boards.writing.comments
        #expect(comments.contains { $0.issue == issue.id && $0.body.contains("web") })
    }

    @Test("A missing path on the mainline halts authoring, naming the repository")
    func missingPathOnMainlineHaltsAuthoring() async throws {
        let fixture = EngineGitFixture()
        await fixture.initRepo()
        try await fixture.commit(filename: "present.swift", content: "struct Present {}")
        let repo = Repo(name: "mobile", path: fixture.path, role: .mobile)
        let repositories = ProjectRepositories(
            workingRepos: [Repo(name: "backend", path: "/repos/backend", role: .backend), repo],
            specSource: SpecSource(path: "/repos/spec")
        )

        let kind = try authoringKind()
        let breakdown = FeatureBreakdown(
            definitionOfDone: [authoringClause("The Feature is done.")],
            cards: [
                CardDraft(
                    repository: "backend", kind: kind, title: "Backend one", unitOfWork: "Do it",
                    brief: "Approach.",
                    definitionOfDone: [authoringClause("Backend one is done.")],
                    contracts: [ContractDraft(repository: "mobile", paths: ["missing.swift"])]
                )
            ]
        )
        let rig = try await AuthoringRig(drafting: ScriptedBreakdown(breakdown), transcribing: MainlineReader())
        let context = try makeSelectionContext(
            rig.journal, repositories: repositories, boards: rig.boards, mainlines: ResolvedMainlines()
        ).context

        let outcome = try await rig.run(context)

        #expect(outcome == .halted)
        #expect(try tableRowCount(rig.journal, table: "card") == 0)
        let event = try #require(try rig.journal.events().first { $0.type == .featureAuthoringHalted })
        guard case .featureAuthoringHalted(_, let kind, let detail) = event.event else {
            Issue.record("expected featureAuthoringHalted")
            return
        }
        #expect(kind == "contract-unreadable")
        #expect(detail?.contains("mobile") == true)
    }

    @Test("Nil Project repositories makes every contract unreadable (AuthoringTranscriptions unit)")
    func nilRepositoriesMakesContractsUnreadable() async throws {
        // A nil `context.repositories` also makes every drafted clause uncitable, so the full
        // transaction halts on the citation gate first (roadmap P9.5) before ever reaching contract
        // transcription — this exercises ``AuthoringTranscriptions`` directly, the seam that must never
        // guess when it is handed no repositories to read against.
        let kind = try authoringKind()
        let breakdown = FeatureBreakdown(
            definitionOfDone: [authoringClause("The Feature is done.")],
            cards: [
                CardDraft(
                    repository: "backend", kind: kind, title: "Backend one", unitOfWork: "Do it",
                    brief: "Approach.",
                    definitionOfDone: [authoringClause("Backend one is done.")],
                    contracts: [ContractDraft(repository: "mobile", paths: ["a.swift"])]
                )
            ]
        )
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, _) = try makeSelectionContext(journal, repositories: nil)

        let resolution = await AuthoringTranscriptions.resolve(
            breakdown, using: FakeContractTranscriber(), context: context
        )

        #expect(resolution.isReadable == false)
        #expect(resolution.unreadable.count == 1)
        let unreadable = try #require(resolution.unreadable.first)
        #expect(unreadable.cardTitle == "Backend one")
        #expect(unreadable.repository == "mobile")
        #expect(unreadable.reason.contains("no repositories configured"))
    }

    @Test("Two unreadable contracts in different repositories both halt authoring, and both are named")
    func twoUnreadableContractsBothNamed() async throws {
        let kind = try authoringKind()
        let breakdown = FeatureBreakdown(
            definitionOfDone: [authoringClause("The Feature is done.")],
            cards: [
                CardDraft(
                    repository: "backend", kind: kind, title: "Backend one", unitOfWork: "Do it",
                    brief: "Approach.",
                    definitionOfDone: [authoringClause("Backend one is done.")],
                    contracts: [ContractDraft(repository: "mobile", paths: ["a.swift"])]
                ),
                CardDraft(
                    repository: "mobile", kind: kind, title: "Mobile one", unitOfWork: "Do it",
                    brief: "Approach.",
                    definitionOfDone: [authoringClause("Mobile one is done.")],
                    contracts: [ContractDraft(repository: "backend", paths: ["b.swift"])]
                )
            ]
        )
        let rig = try await AuthoringRig(
            drafting: ScriptedBreakdown(breakdown),
            transcribing: FakeContractTranscriber(unreadableRepositories: ["mobile", "backend"])
        )

        let outcome = try await rig.run(rig.context())

        #expect(outcome == .halted)
        #expect(try tableRowCount(rig.journal, table: "feature") == 0)
        #expect(try tableRowCount(rig.journal, table: "card") == 0)
        #expect(try rig.journal.events(ofType: .featureAuthoringAccepted).isEmpty)

        let event = try #require(try rig.journal.events().first { $0.type == .featureAuthoringHalted })
        guard case .featureAuthoringHalted(let name, let kind, let detail) = event.event else {
            Issue.record("expected featureAuthoringHalted")
            return
        }
        #expect(name == "FEAT-1")
        #expect(kind == "contract-unreadable")
        #expect(detail?.contains("mobile") == true)
        #expect(detail?.contains("backend") == true)

        let live = await rig.boards.writing.liveIssues
        let issue = try #require(live.first { $0.title == "FEAT-1" })
        let comments = await rig.boards.writing.comments
        #expect(comments.contains {
            $0.issue == issue.id && $0.body.contains("mobile") && $0.body.contains("backend")
        })
    }

    @Test("A Card with an empty or whitespace-only brief is an authoring fault, not a throw")
    func emptyBriefRefusesAuthoring() async throws {
        let kind = try authoringKind()
        let breakdown = FeatureBreakdown(
            definitionOfDone: [authoringClause("x")],
            cards: [
                CardDraft(
                    repository: "backend", kind: kind, title: "Backend one", unitOfWork: "Do it",
                    brief: "   ",
                    definitionOfDone: [authoringClause("x")]
                )
            ]
        )
        let rig = try await AuthoringRig(drafting: ScriptedBreakdown(breakdown))

        let outcome = try await rig.run(rig.context())

        #expect(outcome == .authoringRolledBack)
        #expect(try tableRowCount(rig.journal, table: "outbox") == 0)
        #expect(try rig.journal.events(ofType: .featureAuthoringAccepted).isEmpty)
        #expect(await rig.boards.writing.liveIssues.isEmpty)
        let rejected = try #require(try rig.journal.events(ofType: .featureBreakdownRejected).first)
        guard case .featureBreakdownRejected(let name, let reason) = rejected.event else {
            Issue.record("expected featureBreakdownRejected")
            return
        }
        #expect(name == "FEAT-1")
        #expect(reason.contains("Architectural Brief"))
    }
}
