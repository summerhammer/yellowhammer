import Domain
import Foundation
import Repositories
import Testing

// P7.1: result schema and instruction contract

private func makeInstruction(
    payloads: InstructionPayloads, check: Check = .command("swift test"), pass: RunPass = .worker,
    laneStack: LaneStackContext? = nil
) -> Instruction {
    let night = NightStart(rawValue: "2026-09-17")!
    let repo = Repo(name: "yellowhammer", path: "/repos/yellowhammer", role: .backend)
    let brief = ArchitecturalBrief(
        prose: "Add the result schema and instruction contract.",
        transcriptions: [
            TranscriptionBlock(
                repository: "yellowhammer-spec",
                paths: ["docs/adr/ADR-001-ports.md"],
                symbol: "Port",
                mainlineCommit: String(repeating: "c", count: 40),
                content: "An adapter translates; it never decides.",
                contentHash: "hash1",
                authorSupplied: false
            ),
            TranscriptionBlock(
                repository: "yellowhammer-spec",
                paths: ["docs/glossary.md"],
                symbol: nil,
                mainlineCommit: String(repeating: "d", count: 40),
                content: "Operator-supplied clarification.",
                contentHash: "hash2",
                authorSupplied: true,
                authorSuppliedNight: night
            )
        ]
    )
    let dod = [
        DoDClause(id: "D-1", text: "Decode every valid fixture.", citation: "roadmap/P7.1"),
        DoDClause(id: "D-2", text: "Reject an empty result file.")
    ]
    let route = Route(cli: "claude", model: "sonnet", effort: "medium")!
    return Instruction(
        pass: pass,
        card: InstructionCard(key: "ENG-1", title: "Result schema and instruction contract", description: "Ship P7.1."),
        brief: brief,
        definitionOfDone: dod,
        repository: InstructionRepository(
            repo: repo,
            worktreePath: "/worktrees/yellowhammer/ENG-1",
            featureBranch: "feature/eng-1",
            check: check
        ),
        route: route,
        payloads: payloads,
        laneStack: laneStack
    )
}

private func fullPayloads() -> InstructionPayloads {
    let askedOn = NightStart(rawValue: "2026-09-10")!
    let bankedNight = NightStart(rawValue: "2026-09-12")!
    return InstructionPayloads(
        wip: WIPContext(commit: String(repeating: "d", count: 40), note: "reset from a killed Attempt"),
        answeredQuestion: AnsweredQuestion(
            question: "Should the commit be 40-hex or short form?",
            askedOn: askedOn,
            replies: [
                OperatorReply(
                    body: "Full 40-hex, always.",
                    repliedAt: Date(timeIntervalSince1970: 1_757_000_000),
                    commentID: "comment-1"
                )
            ]
        ),
        bankedReplies: [
            BankedReply(
                body: "Use the existing SpecCitation type, do not invent a new one.",
                night: bankedNight,
                mainlineCommits: ["yellowhammer": String(repeating: "e", count: 40)],
                commentID: "comment-2"
            )
        ],
        roundFeedback: [
            RoundFeedback(
                round: 1,
                lens: .review,
                verdict: "changes_requested",
                requestedChanges: "Add the empty/malformed fixtures.",
                judgedCommit: String(repeating: "f", count: 40)
            )
        ]
    )
}

@Test("Sections render in the fixed order")
func sectionsRenderInFixedOrder() {
    let rendered = makeInstruction(payloads: fullPayloads()).render()
    let headings = [
        "## Card",
        "## Architectural Brief",
        "## Definition of Done",
        "## Repository",
        "## Work in progress",
        "## Your earlier question, answered",
        "## Banked replies",
        "## Previous rounds",
        "## Result contract"
    ]
    let indices = headings.map { heading -> String.Index in
        guard let range = rendered.range(of: heading) else {
            Issue.record("missing heading \(heading)")
            return rendered.startIndex
        }
        return range.lowerBound
    }
    #expect(indices == indices.sorted())
}

@Test("An Operator-supplied block's Mainline line carries its commit and the Night the edit was seen")
func operatorSuppliedBlockMainlineLabel() {
    let rendered = makeInstruction(payloads: .none).render()
    #expect(rendered.contains("Mainline: \(String(repeating: "c", count: 40))\n"))
    #expect(rendered.contains("Mainline: \(String(repeating: "d", count: 40)) (Operator-supplied, as of 2026-09-17)\n"))

    let undated = TranscriptionBlock(
        repository: "api", paths: ["a.md"], mainlineCommit: "abc1234", content: "x", contentHash: "h",
        authorSupplied: true
    )
    let repo = Repo(name: "yellowhammer", path: "/repos/yellowhammer", role: .backend)
    let copy = Instruction(
        pass: .worker, card: InstructionCard(key: "ENG-1", title: "Card", description: "Do it."),
        brief: ArchitecturalBrief(prose: "Approach.", transcriptions: [undated]),
        definitionOfDone: [DoDClause(id: "D-1", text: "Done.", citation: nil)],
        repository: InstructionRepository(
            repo: repo, worktreePath: "/worktrees/yellowhammer/ENG-1", featureBranch: "feature/eng-1",
            check: .command("swift test")
        ),
        route: Route(cli: "claude", model: "sonnet", effort: "medium")!, payloads: .none
    )
    #expect(copy.render().contains("Mainline: abc1234 (Operator-supplied)\n"))
}

@Test("Banked replies section states the unverified, dated, Operator-supplied caveat")
func bankedRepliesSectionStatesCaveat() {
    let rendered = makeInstruction(payloads: fullPayloads()).render()
    #expect(rendered.contains("Operator-supplied"))
    #expect(rendered.contains("unverified"))
    #expect(rendered.contains("as they now stand"))
    #expect(rendered.contains("2026-09-12"))
    #expect(rendered.contains(String(repeating: "e", count: 40)))
}

@Test("WIP section contains the commit and never calls it known-good")
func wipSectionContainsCommitNotKnownGood() {
    let rendered = makeInstruction(payloads: fullPayloads()).render()
    #expect(rendered.contains(String(repeating: "d", count: 40)))
    #expect(rendered.contains("not known-good"))
    #expect(!rendered.contains("is known-good"))
}

@Test("Result contract names no file path, and states the schema identifier and permitted outcomes")
func resultContractNamesSchemaAndOutcomesButNoPath() {
    let instruction = makeInstruction(payloads: .none)
    let rendered = instruction.render()
    #expect(!rendered.contains("result.json"))
    #expect(rendered.contains("final structured response"))
    #expect(rendered.contains(
        "conforming to the supplied JSON schema. The CLI Adapter persists it; do not create or edit a result "
            + "file with tools."
    ))
    #expect(!rendered.contains("Write the result file"))
    #expect(rendered.contains("yellowhammer.result.worker"))
    #expect(rendered.contains("completed"))
    #expect(rendered.contains("question"))
    #expect(rendered.contains("failed"))
}

@Test("Every Card pass states the boundary just before the Result contract")
func everyCardPassStatesTheBoundary() throws {
    for pass in [RunPass.architect, .worker, .reviewer] {
        let rendered = makeInstruction(payloads: .none, pass: pass).render()
        #expect(rendered.contains(PassBoundaries.statement))
        let boundaries = try #require(rendered.range(of: "## Boundaries"))
        let contract = try #require(rendered.range(of: "## Result contract"))
        #expect(boundaries.upperBound <= contract.lowerBound)
    }
}

@Test("The worker result contract states the commit obligation and its precedence; other passes do not")
func workerResultContractStatesCommitObligation() {
    let worker = makeInstruction(payloads: .none).render()
    #expect(worker.contains("`completed` carries `commit` (the 40-hex SHA of the commit you made) and `summary`"))
    #expect(worker.contains("nothing in the Card, the Architectural Brief, or the Definition of Done overrides it"))
    #expect(worker.contains("not to commit or to leave your work uncommitted does not apply"))
    #expect(worker.contains("do not create or edit a result file with tools"))
    #expect(!worker.contains("not to write the result file does not apply"))
    for pass in [RunPass.architect, .reviewer] {
        let rendered = makeInstruction(payloads: .none, pass: pass).render()
        #expect(!rendered.contains("40-hex SHA"))
        #expect(!rendered.contains("overrides it"))
    }
}

@Test("An instruction with no payloads renders none of the four payload headings")
func noPayloadsRendersNoPayloadHeadings() {
    let rendered = makeInstruction(payloads: .none).render()
    #expect(!rendered.contains("## Work in progress"))
    #expect(!rendered.contains("## Your earlier question, answered"))
    #expect(!rendered.contains("## Banked replies"))
    #expect(!rendered.contains("## Previous rounds"))
}

@Test("Rendering the same instruction twice yields identical strings")
func renderingIsDeterministic() {
    let instruction = makeInstruction(payloads: fullPayloads())
    #expect(instruction.render() == instruction.render())
}

@Test("check = .none renders the declared-none wording")
func checkNoneRendersDeclaredNoneWording() {
    let rendered = makeInstruction(payloads: .none, check: .none).render()
    #expect(rendered.contains("none: declared `check = none`"))
}

@Test(
    "The authoring-invariant sentence renders for the architect and worker passes, never the reviewer's",
    arguments: RunPass.allCases
)
func authoringInvariantSentenceOnlyForArchitectAndWorker(_ pass: RunPass) {
    let rendered = makeInstruction(payloads: .none, pass: pass).render()
    let sentence = "Cards in a Feature never depend on each other"
    switch pass {
    case .architect, .worker:
        #expect(rendered.contains(sentence))
        #expect(rendered.contains("authoring_invariant_violation"))
        #expect(rendered.contains(
            "Required work absent from another repository's usable mainline or release is an "
                + "authoring-invariant violation"
        ))
        #expect(rendered.contains("never complete against unmerged or unreleased work"))
        #expect(rendered.contains(
            "Raising a version pin or updating a lockfile to an available version that contains "
                + "what this Card needs remains this Card's own work"
        ))
        #expect(rendered.contains(
            "Work already committed on the Feature branch at Base commit by an earlier completed Card in "
                + "the same repository lane is part of this Card's starting tree, not missing work."
        ))
    case .reviewer, .selection, .breakdown, .verifier:
        #expect(!rendered.contains(sentence))
        #expect(!rendered.contains("part of this Card's starting tree"))
    }
}

@Test("Repo lane section is omitted when nil and renders after Repository for architect and worker passes")
func repoLaneSectionRendersForArchitectAndWorker() throws {
    #expect(!makeInstruction(payloads: .none).render().contains("## Repo lane"))

    let base = String(repeating: "1", count: 40)
    let stack = LaneStackContext(
        baseCommit: base,
        completedEarlierCards: [
            LaneCompletedCard(key: "ENG-0", title: "Seed schema"),
            LaneCompletedCard(key: "ENG-0B", title: "Add parser")
        ]
    )
    for pass in [RunPass.architect, .worker] {
        let rendered = makeInstruction(payloads: fullPayloads(), pass: pass, laneStack: stack).render()
        let repoRange = try #require(rendered.range(of: "## Repository"))
        let laneRange = try #require(rendered.range(of: "## Repo lane"))
        let wipRange = try #require(rendered.range(of: "## Work in progress"))
        #expect(repoRange.upperBound < laneRange.lowerBound)
        #expect(laneRange.upperBound < wipRange.lowerBound)
        #expect(rendered.contains("Base commit: \(base)"))
        #expect(!rendered.contains("Worker commit:"))
        #expect(rendered.contains(
            "Completed earlier in this repository's lane:\n\n- ENG-0: Seed schema\n- ENG-0B: Add parser"
        ))
        #expect(rendered.contains(
            "Their work is already committed on the Feature branch at `\(base)`. Build on top of `\(base)` and "
                + "commit new changes without resetting or amending earlier Cards' commits."
        ))
    }
}

@Test("Repo lane section renders baseCommit..judgedCommit review range for reviewer pass")
func repoLaneSectionRendersReviewRangeForReviewer() {
    let base = String(repeating: "1", count: 40)
    let judged = String(repeating: "2", count: 40)
    let stack = LaneStackContext(
        baseCommit: base,
        judgedCommit: judged,
        completedEarlierCards: [LaneCompletedCard(key: "ENG-0", title: "Seed schema")]
    )
    let rendered = makeInstruction(payloads: .none, pass: .reviewer, laneStack: stack).render()
    #expect(rendered.contains("## Repo lane\n\nBase commit: \(base)\nWorker commit: \(judged)"))
    #expect(rendered.contains(
        "Judge the changes in `\(base)..\(judged)` against this Card's Definition of Done. Commits at or before "
            + "`\(base)` on the Feature branch belong to the recorded base or earlier completed Cards in this "
            + "repository's lane."
    ))
    #expect(rendered.contains("Completed earlier in this repository's lane:\n\n- ENG-0: Seed schema"))
    #expect(!rendered.contains("Build on top of"))
}

@Test(
    "The sibling-repository read rule renders for architect, worker, and reviewer passes, never other passes",
    arguments: RunPass.allCases
)
func siblingRepositoryReadRuleRendersForWorkCardPasses(_ pass: RunPass) {
    let rendered = makeInstruction(payloads: .none, pass: pass).render()
    let sentence = "Another repository is read for Work Card work only through the Architectural Brief's "
        + "mainline transcription, never through a sibling Worktree or another Feature Branch."
    switch pass {
    case .architect, .worker, .reviewer:
        #expect(rendered.contains(sentence))
    case .selection, .breakdown, .verifier:
        #expect(!rendered.contains(sentence))
    }
}

@Test("""
    The agent CLI never reads the Spec Source (roadmap P9.6; spec: feature-authoring/\
    author-an-architectural-brief): a Spec Source Transcription Block reaches the instruction only as \
    block content under the repository name, never the Spec Source's own filesystem path
    """)
func renderedInstructionNeverCarriesTheSpecSourcePath() async throws {
    // `Instruction` and ``ArchitecturalBrief``/``TranscriptionBlock`` never carry a `SpecSource` value —
    // only the repository NAME ("spec_source") and block content — so no pipeline that builds an
    // Instruction from them can thread a Spec Source's filesystem path into it, even by accident
    // (``CardRun+Passes.swift``'s `instruction(for:route:frame:payloads:)` takes `frame.readiness.brief`
    // and `frame.repository`, a `Domain.Repo?`, never a `Repositories.SpecSource`). This transcribes a
    // real Spec Source whose checkout sits at a distinctive path, from a Project that reads it, and
    // confirms the rendered instruction never carries that path.
    let fixture = EngineGitFixture()
    await fixture.initRepo()
    try await fixture.commit(filename: "docs/glossary.md", content: "A Card is the smallest unit of work.")
    let specSource = SpecSource(path: fixture.path)
    let repositories = ProjectRepositories(workingRepos: [], specSource: specSource)
    let transcribedBlock = try await MainlineReader().transcribe(
        path: "docs/glossary.md", repository: "spec_source", in: repositories
    )

    let brief = ArchitecturalBrief(prose: "Approach.", transcriptions: [transcribedBlock])
    let repo = Repo(name: "yellowhammer", path: "/repos/yellowhammer", role: .backend)
    let instruction = Instruction(
        pass: .worker,
        card: InstructionCard(key: "ENG-1", title: "Card", description: "Do it."),
        brief: brief,
        definitionOfDone: [DoDClause(id: "D-1", text: "Done.", citation: nil)],
        repository: InstructionRepository(
            repo: repo, worktreePath: "/worktrees/yellowhammer/ENG-1", featureBranch: "feature/eng-1",
            check: .command("swift test")
        ),
        route: Route(cli: "claude", model: "sonnet", effort: "medium")!,
        payloads: .none
    )

    let rendered = instruction.render()

    #expect(!rendered.contains(fixture.path))
    #expect(rendered.contains("spec_source"))
    #expect(rendered.contains("A Card is the smallest unit of work."))
}

@Test("A ranged block names its lines in the header and holds the Journal's transcribed lines")
func rangedBlockHeaderNamesItsLines() {
    let ranged = TranscriptionBlock(
        repository: "api", paths: ["openapi.yaml", "models.swift", "notes.md"],
        ranges: [
            "openapi.yaml": [LineRange(start: 120, end: 180), LineRange(start: 200, end: 210)],
            "notes.md": [LineRange(start: 7, end: 7)]
        ],
        symbol: "ClassList", mainlineCommit: String(repeating: "a", count: 40),
        content: "distinctive transcribed line", contentHash: "h", authorSupplied: false
    )
    let whole = TranscriptionBlock(
        repository: "api", paths: ["models.swift"], mainlineCommit: nil, content: "whole file",
        contentHash: "h2", authorSupplied: false
    )
    let repo = Repo(name: "yellowhammer", path: "/repos/yellowhammer", role: .backend)
    let instruction = Instruction(
        pass: .worker, card: InstructionCard(key: "ENG-1", title: "Card", description: "Do it."),
        brief: ArchitecturalBrief(prose: "Approach.", transcriptions: [ranged, whole]),
        definitionOfDone: [DoDClause(id: "D-1", text: "Done.", citation: nil)],
        repository: InstructionRepository(
            repo: repo, worktreePath: "/worktrees/yellowhammer/ENG-1", featureBranch: "feature/eng-1",
            check: .command("swift test")
        ),
        route: Route(cli: "claude", model: "sonnet", effort: "medium")!, payloads: .none
    )

    let rendered = instruction.render()

    #expect(rendered.contains("Paths: openapi.yaml, models.swift, notes.md\nLines: "
        + "openapi.yaml lines 120–180, 200–210; notes.md line 7\nSymbol: ClassList"))
    #expect(rendered.contains("distinctive transcribed line"))
    // The unranged block has no Lines: line at all.
    #expect(rendered.components(separatedBy: "Lines: ").count == 2)
}
