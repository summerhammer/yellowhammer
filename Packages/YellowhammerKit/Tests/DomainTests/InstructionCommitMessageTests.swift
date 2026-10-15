import Domain
import Testing

// graph-execution/run-a-card: the worker pass's instruction states the rendered commit message and
// asks for a Yellowhammer-Work-Card trailer; no other pass renders the section.

private func makeInstruction(
    pass: RunPass, commitMessage: CommitMessageRequest?, specCommit: String? = nil, passTimeoutMinutes: Int? = nil
) -> Instruction {
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
        specCommit: specCommit,
        passTimeoutMinutes: passTimeoutMinutes,
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

                Yellowhammer-Work-Card: YLH-42

            Every commit you make for this Card carries the git trailer `Yellowhammer-Work-Card: YLH-42` \
            in its last paragraph, in the same block as any trailers the repository's own conventions ask for \
            (such as `Spec:` or `Co-Authored-By:`). Those conventions add trailers; they do not replace this \
            one. A trailer separated from that block by a blank line is not read.
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

@Test("stamping the result file path keeps the request, so the text the CLI receives still asks for the trailer")
func stampingTheResultFilePathKeepsTheRequest() {
    // Night 2026-10-12: every worker commit lacked the trailer because the stamped copy dropped the request.
    let request = CommitMessageRequest(message: "feat: YLH-42 a card", workCardKey: "YLH-42")
    let stamped = makeInstruction(pass: .worker, commitMessage: request)
        .withResultFilePath("/runs/proj/run-1/YLH-42/1-worker/result.json")

    #expect(stamped.commitMessage == request)
    #expect(stamped.resultFilePath == "/runs/proj/run-1/YLH-42/1-worker/result.json")
    let text = stamped.render()
    #expect(text.contains("## Commit messages"))
    #expect(text.contains("Yellowhammer-Work-Card: YLH-42"))
    #expect(text.contains("/runs/proj/run-1/YLH-42/1-worker/result.json"))
}

// OQ165 (graph-execution/run-a-card#spec-commit): the worker instruction names the specification commit
// and tells the worker not to search outside its Worktree; it adds no path to the specification.

private let specSha = "0123456789abcdef0123456789abcdef01234567"
private let neverSearch = "Never search the filesystem outside the Worktree — no `find ~`, no `find /`, "
    + "no walking other directories."

@Test("a worker instruction with a specification commit renders it and the never-search sentence")
func workerRendersSpecificationCommitAndNeverSearch() {
    let text = makeInstruction(pass: .worker, commitMessage: nil, specCommit: specSha).render()
    #expect(text.contains("## Specification\n\nSpecification commit: \(specSha)\n"))
    #expect(text.contains("given as a fact, not as a requirement to cite it"))
    #expect(text.contains(neverSearch))
    #expect(text.contains("report the `question` outcome and ask for it rather than searching."))
    let repository = text.range(of: "## Repository")
    let specification = text.range(of: "## Specification")
    let contract = text.range(of: "## Result contract")
    #expect(repository!.lowerBound < specification!.lowerBound)
    #expect(specification!.lowerBound < contract!.lowerBound)
}

@Test("a worker instruction with no specification commit still carries the never-search sentence")
func workerWithoutSpecificationCommitStillNeverSearches() {
    let text = makeInstruction(pass: .worker, commitMessage: nil, specCommit: nil).render()
    #expect(!text.contains("Specification commit:"))
    #expect(text.contains(neverSearch))
}

@Test("architect and reviewer instructions render neither the commit nor the never-search sentence")
func otherPassesRenderNoSpecificationSection() {
    for pass in [RunPass.architect, .reviewer] {
        let text = makeInstruction(pass: pass, commitMessage: nil, specCommit: specSha).render()
        #expect(!text.contains(specSha))
        #expect(!text.contains("## Specification"))
        #expect(!text.contains("Never search the filesystem"))
        #expect(Instruction.stayInsideSentence(for: pass) == nil)
    }
    #expect(Instruction.stayInsideSentence(for: .worker) != nil)
}

// MARK: - Time limit (#507)

@Test("a worker instruction states the pass timeout and to commit before a long verification run")
func workerRendersTimeLimit() {
    let text = makeInstruction(
        pass: .worker, commitMessage: CommitMessageRequest(message: "feat: a card", workCardKey: "YLH-42"),
        passTimeoutMinutes: 60
    ).render()
    #expect(
        text.contains(
            """
            ## Time limit

            This pass may run for at most 60 minutes, after which Yellowhammer stops it. Work you have not \
            committed by then is preserved, but the Attempt is spent and the next Attempt, if any, runs on a different \
            Route. So commit a coherent step before any long verification run (a full build or a Simulator or \
            device test run). Run focused checks first. Do not wait on a background build or test that will \
            not finish within the limit.
            """
        )
    )
    let commits = text.range(of: "## Commit messages")
    let limit = text.range(of: "## Time limit")
    let contract = text.range(of: "## Result contract")
    #expect(commits != nil && limit != nil && contract != nil)
    #expect(commits!.lowerBound < limit!.lowerBound)
    #expect(limit!.lowerBound < contract!.lowerBound)
    #expect(text.contains("A trailer separated from that block by a blank line is not read.\n\n## Time limit"))
    #expect(text.contains("not finish within the limit.\n\n## Result contract"))
}

@Test("an architect instruction states the shorter time limit")
func architectRendersShorterTimeLimit() {
    let text = makeInstruction(pass: .architect, commitMessage: nil, passTimeoutMinutes: 45).render()
    #expect(
        text.contains(
            "## Time limit\n\nThis pass may run for at most 45 minutes, after which Yellowhammer stops it and "
                + "the Attempt is spent.\n\n## Result contract"
        )
    )
    #expect(!text.contains("commit a coherent step"))
}

@Test("a reviewer instruction renders no time limit even with a timeout set")
func reviewerRendersNoTimeLimit() {
    let text = makeInstruction(pass: .reviewer, commitMessage: nil, passTimeoutMinutes: 60).render()
    #expect(!text.contains("## Time limit"))
}

@Test("a nil pass timeout renders no time limit section on any pass")
func nilTimeoutRendersNoTimeLimit() {
    for pass in [RunPass.architect, .worker, .reviewer] {
        #expect(!makeInstruction(pass: pass, commitMessage: nil).render().contains("## Time limit"))
    }
}
