import Domain
import Testing

// graph-execution/run-a-card: the worker pass's instruction states the rendered commit message and
// asks for a Yellowhammer-Work-Card trailer; no other pass renders the section.

private func makeInstruction(pass: RunPass, commitMessage: CommitMessageRequest?) -> Instruction {
    Instruction(
        pass: pass,
        card: InstructionCard(key: "YLH-42", title: "A card", description: "Do it."),
        brief: ArchitecturalBrief(prose: "Prose.", transcriptions: []),
        definitionOfDone: [DoDClause(id: "D-1", text: "Works.")],
        repository: InstructionRepository(
            repo: Repo(name: "yellowhammer", path: "/repos/yellowhammer", role: .backend),
            worktreePath: "/worktrees/yellowhammer/YLH-42",
            featureBranch: "feature/ylh-42",
            check: .none
        ),
        route: Route(cli: "claude", model: "sonnet", effort: "medium")!,
        payloads: .none,
        commitMessage: commitMessage,
        resultFilePath: "/worktrees/yellowhammer/YLH-42/result.json"
    )
}

@Test("a worker instruction with a request renders the format and the trailer after the Repository section")
func workerRendersCommitMessages() {
    let text = makeInstruction(
        pass: .worker, commitMessage: CommitMessageRequest(message: "feat: YLH-42 a card", workCardKey: "YLH-42")
    ).render()
    #expect(
        text.contains(
            """
            ## Commit messages

            Write each commit message in this format:

                feat: YLH-42 a card

            End each commit message with the git trailer `Yellowhammer-Work-Card: YLH-42`.
            """
        )
    )
    let repository = text.range(of: "## Repository")
    let commits = text.range(of: "## Commit messages")
    let contract = text.range(of: "## Result contract")
    #expect(repository != nil && commits != nil && contract != nil)
    #expect(repository!.lowerBound < commits!.lowerBound)
    #expect(commits!.lowerBound < contract!.lowerBound)
}

@Test("a worker instruction without a Card key renders no trailer sentence")
func workerWithoutCardKeyOmitsTrailer() {
    for key in [nil, ""] as [String?] {
        let text = makeInstruction(
            pass: .worker, commitMessage: CommitMessageRequest(message: "feat: a card", workCardKey: key)
        ).render()
        #expect(text.contains("Write each commit message in this format:\n\n    feat: a card\n\n## Result contract"))
        #expect(!text.contains("Yellowhammer-Work-Card"))
    }
}

@Test("architect and reviewer instructions render no commit messages section")
func otherPassesRenderNoSection() {
    for pass in [RunPass.architect, .reviewer] {
        let text = makeInstruction(
            pass: pass, commitMessage: CommitMessageRequest(message: "feat: a card", workCardKey: "YLH-42")
        ).render()
        #expect(!text.contains("## Commit messages"))
    }
}

@Test("an instruction without a request renders no commit messages section")
func noRequestRendersNoSection() {
    let text = makeInstruction(pass: .worker, commitMessage: nil).render()
    #expect(!text.contains("## Commit messages"))
}
