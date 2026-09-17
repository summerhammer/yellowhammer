import Domain
import Foundation
import Testing

// P7.1: result schema and instruction contract

private func makeInstruction(payloads: InstructionPayloads, check: Check = .command("swift test")) -> Instruction {
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
                mainlineCommit: nil,
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
        pass: .worker,
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
        resultFilePath: "/worktrees/yellowhammer/ENG-1/.yellowhammer/result.json"
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

@Test("Result contract names the file path, schema identifier and permitted outcomes")
func resultContractNamesPathSchemaAndOutcomes() {
    let instruction = makeInstruction(payloads: .none)
    let rendered = instruction.render()
    #expect(rendered.contains(instruction.resultFilePath))
    #expect(rendered.contains("yellowhammer.result.worker"))
    #expect(rendered.contains("completed"))
    #expect(rendered.contains("question"))
    #expect(rendered.contains("failed"))
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
