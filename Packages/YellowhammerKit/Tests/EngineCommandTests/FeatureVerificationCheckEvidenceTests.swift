import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

@Suite("Verification: recorded Check evidence")
struct FeatureVerificationCheckEvidenceTests {
    @Test("The verifier receives historical commands and commits, scoped to the Feature and repository")
    func instructionReceivesRecordedChecks() async throws {
        let world = try await VerificationWorld()
        try world.addClause(issue: "BACK-1", cid: "c1", text: "The tests pass.")
        let card = try #require(try world.journal.card(issueID: "BACK-1"))
        let earlierCard = try insertReconcilerCard(
            world.journal, cycleID: world.cycleID, issueID: "BACK-OLD", repository: "backend", state: .done
        )
        let otherRepoCard = try insertReconcilerCard(
            world.journal, cycleID: world.cycleID, issueID: "OTHER-REPO", repository: "unconfigured", state: .shelved
        )
        let otherFeature = try insertReconcilerFeature(world.journal, issueID: "OTHER-FEATURE")
        let otherCycle = try insertReconcilerCycle(world.journal, featureID: otherFeature)
        let unrelatedCard = try insertReconcilerCard(
            world.journal, cycleID: otherCycle, issueID: "UNRELATED", repository: "backend", state: .done
        )
        try appendCheck(world, cardID: earlierCard, command: "old-command test", commit: "old-head", status: 1)
        try appendCheck(world, cardID: unrelatedCard, command: "unrelated-command", commit: "unrelated", status: 0)
        try appendCheck(world, cardID: otherRepoCard, command: "other-repo-command", commit: "other", status: 0)
        try appendCheck(world, cardID: card.id, command: "new-command test", commit: "new-head", status: 0)
        try world.journal.append(.checkRan(CheckRanPayload(
            cardID: card.id, issueID: card.issueID, attemptID: 1, result: .declaredNone,
            exitStatus: nil, output: nil, judgedCommit: "none-head"
        )))
        let dispatch = ScriptedVerifierDispatch([routeOther: .judgeAll()])

        _ = try await world.verification(resolver: verificationResolver(primary: routeOther), dispatch: dispatch)
            .verify(world.featureContext)

        let request = try #require(dispatch.requests.first)
        guard case .verification(let instruction) = request.instruction else {
            Issue.record("Expected a Verification instruction")
            return
        }
        let repository = try #require(instruction.repositories.first { $0.name == "backend" })
        #expect(repository.checkResults == [
            VerificationCheckResult(command: "old-command test", judgedCommit: "old-head", exitStatus: 1),
            VerificationCheckResult(command: "new-command test", judgedCommit: "new-head", exitStatus: 0)
        ])
        let rendered = instruction.render()
        #expect(rendered.contains("Command: old-command test\n    Judged commit: old-head\n    Exit status: 1"))
        #expect(!rendered.contains("unrelated-command"))
        #expect(!rendered.contains("other-repo-command"))
        #expect(!rendered.contains("none-head"))
        #expect(instruction.clauses.map(\.cid) == ["c1"])
        // A single-repository Feature renders no sibling, lockfile or evidence lines.
        #expect(!rendered.contains("Other repositories when the Check ran"))
        #expect(!rendered.contains("Lockfile:"))
        #expect(!rendered.contains("\n    Evidence:"))
    }

    private let recorded = "9f8e7d6c5b4a39281706f5e4d3c2b1a098765432"
    private let moved = "def56789abcdef0123456789abcdef0123456789"

    private func checkouts(mobile: String? = nil) -> VerifierCheckouts {
        VerifierCheckouts(
            byRepository: mobile.map {
                ["mobile": VerifierCheckout(
                    directory: "/mobile",
                    judged: JudgedCheckout(
                        repository: "mobile", commit: $0, kind: .freshCheckout, noPushedBranch: false
                    )
                )]
            } ?? [:],
            freshRoot: nil
        )
    }

    private func run(_ siblings: [CheckSiblingState], lockfile: LockfileIdentity = .unknown) -> CheckRunRecord {
        CheckRunRecord(
            eventID: 1, attemptID: 1, result: .passed, exitStatus: 0, output: nil, judgedCommit: "head",
            occurredAt: Date(timeIntervalSince1970: 0), command: "make test", siblings: siblings, lockfile: lockfile
        )
    }

    private func render(_ run: CheckRunRecord, checkouts: VerifierCheckouts) -> String {
        VerificationInstruction(
            route: routeOther, featureTitle: "Feature", clauses: [],
            specificationSource: .specSource(SpecSource(path: "/spec")),
            repositories: [VerificationRepository(
                name: "backend", directory: "/backend", featureBranch: "feature", judgedCommit: "head",
                checkResults: [
                FeatureVerification.verificationCheckResult(run, repository: "backend", checkouts: checkouts)
            ]
            )]
        ).render()
    }

    @Test("Siblings at the recorded commit before and after: the record is decisive, with the lockfile shown")
    func siblingsAtTheRecordedCommitAreDecisive() {
        let rendered = render(
            run(
                [
                    CheckSiblingState(repository: "mobile", before: .commit(recorded), after: .commit(recorded))
                ],
                lockfile: .blob(path: "Package.resolved", objectID: "1a2b3c4d5e6f")
            ),
            checkouts: checkouts(mobile: recorded)
        )
        #expect(rendered.contains(
            "    Other repositories when the Check ran: `mobile` at 9f8e7d6 before, 9f8e7d6 after\n"
        ))
        #expect(rendered.contains("    Lockfile: Package.resolved → blob 1a2b3c4\n"))
        #expect(rendered.contains("    Evidence: decisive"))
    }

    @Test("A sibling whose HEAD after the Check is not the recorded commit is not decisive")
    func movedSiblingIsNotDecisive() {
        let rendered = render(
            run(
                [CheckSiblingState(repository: "mobile", before: .commit(recorded), after: .commit(moved))],
                lockfile: .absent(path: "Package.resolved")
            ),
            checkouts: checkouts(mobile: recorded)
        )
        #expect(rendered.contains(
            "    Evidence: not decisive — `mobile` was at 9f8e7d6 before and def5678 after the Check; "
                + "the recorded commit is 9f8e7d6"
        ))
        #expect(rendered.contains("    Lockfile: Package.resolved absent at this commit\n"))
    }

    @Test("A sibling with no held Worktree, an unreadable one or an unrecorded one is not decisive")
    func otherSiblingStatesAreNotDecisive() {
        let noHeld = render(
            run([CheckSiblingState(repository: "mobile", before: .noHeldWorktree, after: .noHeldWorktree)]),
            checkouts: checkouts(mobile: recorded)
        )
        #expect(noHeld.contains("no held Worktree before, no held Worktree after"))
        #expect(noHeld.contains("    Evidence: not decisive — `mobile` had no held Worktree when the Check ran"))
        #expect(noHeld.contains("    Lockfile: unknown (none configured)"))

        let unreadable = render(
            run([CheckSiblingState(
                repository: "mobile", before: .commit(recorded), after: .unreadable(reason: "boom")
            )]),
            checkouts: checkouts(mobile: recorded)
        )
        #expect(unreadable.contains("    Evidence: not decisive — `mobile`: unreadable: boom"))

        let unrecorded = render(
            run([CheckSiblingState(repository: "mobile", before: .commit(recorded), after: .commit(recorded))]),
            checkouts: checkouts()
        )
        #expect(unrecorded.contains("    Evidence: not decisive — `mobile` has no recorded commit to compare with"))
    }

    @Test("A record naming no sibling is not decisive in a multi-repository Feature, and silent in a single one")
    func recordWithoutSiblingsDependsOnTheFeature() {
        let multi = render(run([]), checkouts: checkouts(mobile: recorded))
        #expect(multi.contains("    Other repositories when the Check ran: not recorded\n"))
        #expect(multi.contains(
            "    Evidence: not decisive — the record names no other repository's HEAD: it was written before "
                + "Yellowhammer recorded them"
        ))
        let single = render(run([]), checkouts: checkouts())
        #expect(!single.contains("Other repositories when the Check ran"))
        #expect(!single.contains("\n    Lockfile:"))
        #expect(!single.contains("\n    Evidence:"))
    }

    @Test("Every sibling that is not at its recorded commit is named, joined with semicolons")
    func everyOffendingSiblingIsNamed() {
        let two = VerifierCheckouts(
            byRepository: [
                "mobile": VerifierCheckout(directory: "/m", judged: judged("mobile", recorded)),
                "web": VerifierCheckout(directory: "/w", judged: judged("web", recorded))
            ],
            freshRoot: nil
        )
        let rendered = render(
            run([
                CheckSiblingState(repository: "mobile", before: .commit(recorded), after: .commit(moved)),
                CheckSiblingState(repository: "web", before: .noHeldWorktree, after: .noHeldWorktree)
            ]),
            checkouts: two
        )
        #expect(rendered.contains(
            "`mobile` was at 9f8e7d6 before and def5678 after the Check; the recorded commit is 9f8e7d6; "
                + "`web` had no held Worktree when the Check ran"
        ))
    }

    private func judged(_ repository: String, _ commit: String) -> JudgedCheckout {
        JudgedCheckout(repository: repository, commit: commit, kind: .freshCheckout, noPushedBranch: false)
    }

    @Test("Through Verification, a sibling away from its recorded commit reaches the verifier as not decisive")
    func endToEndSiblingEvidence() async throws {
        let world = try await VerificationWorld(cards: [
            VerificationCard("BACK-1", "backend", .done), VerificationCard("MOB-1", "mobile", .done)
        ])
        try world.addClause(issue: "BACK-1", cid: "c1", text: "The tests pass.")
        let card = try #require(try world.journal.card(issueID: "BACK-1"))
        try world.journal.append(.checkRan(CheckRanPayload(
            cardID: card.id, issueID: card.issueID, attemptID: 1, result: .passed, exitStatus: 0, output: nil,
            judgedCommit: "head", command: "make test",
            siblings: [CheckSiblingState(repository: "mobile", before: .commit(recorded), after: .commit(moved))]
        )))
        let dispatch = ScriptedVerifierDispatch([routeOther: .judgeAll()])
        let verification = FeatureVerification(
            resolver: verificationResolver(primary: routeOther), dispatch: dispatch,
            citations: FakeCitationResolver(),
            checkouts: RecordedCommitCheckouts(commits: ["backend": "head", "mobile": recorded])
        )

        _ = try await verification.verify(world.featureContext)

        let request = try #require(dispatch.requests.first)
        guard case .verification(let instruction) = request.instruction else {
            Issue.record("Expected a Verification instruction")
            return
        }
        #expect(instruction.render().contains(
            "    Evidence: not decisive — `mobile` was at 9f8e7d6 before and def5678 after the Check; "
                + "the recorded commit is 9f8e7d6"
        ))
    }

    @Test("The instruction states that a not-decisive record decides no clause and the lockfile never does")
    func ruleSentenceIsInTheInstruction() {
        let rendered = render(run([]), checkouts: checkouts())
        #expect(rendered.contains(
            "A record marked `Evidence: not decisive` does not decide a clause either: name that record and its "
                + "reason beside the clause in `what_was_checked`. The lockfile identity is for your information "
                + "and never decides evidence."
        ))
    }

    @Test("The instruction names evidence limits, stale commits and uncovered commands on every Route")
    func instructionExplainsEvidenceLimits() {
        let instruction = VerificationInstruction(
            route: routeOther, featureTitle: "Feature", clauses: [],
            specificationSource: .specSource(SpecSource(path: "/spec")),
            repositories: [VerificationRepository(
                name: "backend", directory: "/backend", featureBranch: "feature", judgedCommit: "pushed-tip",
                checkResults: [VerificationCheckResult(command: nil, judgedCommit: nil, exitStatus: 0)]
            ), VerificationRepository(
                name: "other", directory: "/other", featureBranch: "feature", judgedCommit: "base-commit",
                noPushedBranch: true
            )]
        )
        let rendered = instruction.render()
        #expect(rendered.contains("judge clauses they cover, on any Route"))
        // OQ191 item 2 (#recorded-check-results, reworded 2026-10-29): a record decides a clause only at the
        // commit judged — the Pushed Tip, or the recorded base commit — never at the Feature Branch's head.
        #expect(!rendered.contains("Resolve the head"))
        #expect(rendered.contains("does not decide a clause: name that record beside the clause"))
        #expect(rendered.contains("Feature Branch: feature\n  Checkout at: pushed-tip (the Pushed Tip)"))
        #expect(rendered.contains("Checkout at: base-commit (no pushed branch: the recorded base commit)"))
        #expect(rendered.contains("naming the command it would need"))
        #expect(rendered.contains("otherwise report `not checked`"))
        #expect(rendered.contains("Command: not recorded\n    Judged commit: not recorded\n    Exit status: 0"))
        #expect(rendered.contains("Recorded Check results: none"))
    }

    private func appendCheck(
        _ world: VerificationWorld, cardID: Int64, command: String, commit: String, status: Int32
    ) throws {
        let card = try world.journal.card(id: cardID)
        try world.journal.append(.checkRan(CheckRanPayload(
            cardID: cardID, issueID: card.issueID, attemptID: 1,
            result: status == 0 ? .passed : .failed, exitStatus: status, output: nil,
            judgedCommit: commit, command: command
        )))
    }
}

/// Like ``UnrecordedCheckouts``, but names a judged commit per repository, so Verification can compare each
/// sibling's recorded HEAD with it.
private struct RecordedCommitCheckouts: VerifierCheckoutPreparing {
    let commits: [String: String]

    func plan(_ context: LandActFeatureContext, repositories: [String]) async throws -> VerifierCheckoutPlan {
        VerifierCheckoutPlan(repositories: repositories, judgedCheckouts: [])
    }

    func materialise(_ plan: VerifierCheckoutPlan, context: LandActFeatureContext) async throws -> VerifierCheckouts {
        VerifierCheckouts(
            byRepository: Dictionary(uniqueKeysWithValues: plan.repositories.map { name in
                (name, VerifierCheckout(
                    directory: "/checkout/\(name)",
                    judged: commits[name].map {
                        JudgedCheckout(repository: name, commit: $0, kind: .freshCheckout, noPushedBranch: false)
                    }
                ))
            }),
            freshRoot: nil
        )
    }

    func release(_ checkouts: VerifierCheckouts) {}
}
