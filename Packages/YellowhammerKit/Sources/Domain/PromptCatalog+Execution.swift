import Foundation

extension PromptCatalog {
    static var workerEntry: PromptCatalogEntry {
        let repo = Repo(name: "⟨repo name⟩", path: "⟨repo path⟩", role: .backend)
        let makeBase = { (payloads: InstructionPayloads) in
            Instruction(
                pass: .worker,
                card: InstructionCard(
                    key: "⟨work card key⟩",
                    title: "⟨work card title⟩",
                    description: "⟨work card description⟩"
                ),
                brief: ArchitecturalBrief(
                    prose: "⟨architectural brief prose⟩",
                    transcriptions: [
                        TranscriptionBlock(
                            repository: "⟨transcription repository⟩",
                            paths: ["⟨transcription path⟩"],
                            ranges: ["⟨transcription path⟩": [LineRange(start: 10, end: 20)]],
                            symbol: "⟨transcription symbol⟩",
                            mainlineCommit: "⟨transcription commit⟩",
                            content: "⟨transcription content⟩",
                            contentHash: "⟨content hash⟩",
                            authorSupplied: true,
                            authorSuppliedNight: NightStart(rawValue: "9999-12-31")
                        )
                    ]
                ),
                definitionOfDone: [
                    DoDClause(
                        id: "⟨clause id⟩",
                        text: "⟨clause text⟩",
                        citation: SpecCitation("⟨epic⟩/⟨story⟩")
                    )
                ],
                repository: InstructionRepository(
                    repo: repo,
                    worktreePath: "⟨worktree path⟩",
                    featureBranch: "⟨feature branch⟩",
                    check: .command("⟨check command⟩")
                ),
                route: Route(cli: "⟨cli⟩", model: "⟨model⟩", effort: "⟨effort⟩")!,
                payloads: payloads,
                commitMessage: CommitMessageRequest(
                    message: "⟨commit message format⟩",
                    workCardKey: "⟨work card key⟩"
                ),
                specCommit: "⟨specification commit⟩",
                passTimeoutMinutes: 999,
                laneStack: LaneStackContext(
                    baseCommit: "⟨base commit⟩",
                    completedEarlierCards: [
                        LaneCompletedCard(key: "⟨earlier card key⟩", title: "⟨earlier card title⟩")
                    ]
                )
            )
        }

        let newSessionInstruction = makeBase(.none)
        let newSessionCandidates = [
            "⟨work card key⟩",
            "⟨work card title⟩",
            "⟨work card description⟩",
            "⟨architectural brief prose⟩",
            "⟨transcription repository⟩",
            "⟨transcription path⟩",
            "lines 10–20",
            "⟨transcription symbol⟩",
            "⟨transcription commit⟩",
            "9999-12-31",
            "⟨transcription content⟩",
            "⟨clause id⟩",
            "⟨clause text⟩",
            "⟨epic⟩/⟨story⟩",
            "⟨repo name⟩",
            "backend",
            "⟨worktree path⟩",
            "⟨feature branch⟩",
            "⟨check command⟩",
            "⟨base commit⟩",
            "⟨earlier card key⟩",
            "⟨earlier card title⟩",
            "⟨specification commit⟩",
            "⟨commit message format⟩",
            "999"
        ]
        let newSessionVariant = makeVariant(
            name: "New session",
            template: newSessionInstruction.render(),
            candidatePlaceholders: newSessionCandidates
        )

        let repliedAt = Date(timeIntervalSince1970: 253402300799) // 9999-12-31T23:59:59Z
        let resumedPayloads = InstructionPayloads(
            wip: WIPContext(
                commit: "⟨wip commit⟩",
                note: "⟨wip note⟩",
                outcome: .usageLimited,
                rounds: [
                    RoundFeedback(
                        round: 98,
                        lens: .review,
                        verdict: "⟨prior attempt round verdict⟩",
                        requestedChanges: "⟨prior attempt requested changes⟩",
                        judgedCommit: "⟨prior attempt judged commit⟩"
                    )
                ]
            ),
            answeredQuestion: AnsweredQuestion(
                question: "⟨answered question⟩",
                askedOn: NightStart(rawValue: "9999-12-30")!,
                replies: [
                    OperatorReply(
                        body: "⟨operator reply⟩",
                        repliedAt: repliedAt,
                        commentID: "⟨operator reply comment id⟩"
                    )
                ]
            ),
            bankedReplies: [
                BankedReply(
                    body: "⟨banked reply⟩",
                    night: NightStart(rawValue: "9999-12-29")!,
                    mainlineCommits: ["⟨repo name⟩": "⟨banked mainline commit⟩"],
                    commentID: "⟨banked comment id⟩"
                )
            ],
            roundFeedback: [
                RoundFeedback(
                    round: 99,
                    lens: .review,
                    verdict: "⟨round verdict⟩",
                    requestedChanges: "⟨requested changes⟩",
                    judgedCommit: "⟨judged commit⟩"
                )
            ]
        )
        let resumedInstruction = makeBase(resumedPayloads)
        let resumedCandidates = newSessionCandidates + [
            "⟨wip commit⟩",
            "⟨wip note⟩",
            "usage-limited",
            "Round 98",
            "review",
            "⟨prior attempt round verdict⟩",
            "⟨prior attempt requested changes⟩",
            "⟨prior attempt judged commit⟩",
            "⟨answered question⟩",
            "9999-12-30",
            "9999-12-31T23:59:59Z",
            "⟨operator reply⟩",
            "9999-12-29",
            "⟨banked comment id⟩",
            "⟨banked reply⟩",
            "⟨banked mainline commit⟩",
            "Round 99",
            "⟨round verdict⟩",
            "⟨requested changes⟩",
            "⟨judged commit⟩"
        ]
        let resumedVariant = makeVariant(
            name: "Resumed round",
            template: resumedInstruction.render(),
            candidatePlaceholders: resumedCandidates
        )

        return PromptCatalogEntry(
            family: .worker,
            title: "Worker",
            purpose: "Implements a Work Card, satisfies the Definition of Done, "
                + "passes repository Checks, and commits the work.",
            defaultVersion: PromptFamily.worker.defaultVersion,
            acceptsProjectInstructions: PromptFamily.worker.acceptsProjectInstructions,
            variants: [newSessionVariant, resumedVariant]
        )
    }

    static var reviewerEntry: PromptCatalogEntry {
        let repo = Repo(name: "⟨repo name⟩", path: "⟨repo path⟩", role: .backend)
        let makeInstruction = { (lens: Lens) in
            Instruction(
                pass: .reviewer,
                card: InstructionCard(
                    key: "⟨work card key⟩",
                    title: "⟨work card title⟩",
                    description: "⟨work card description⟩"
                ),
                brief: ArchitecturalBrief(
                    prose: "⟨architectural brief prose⟩",
                    transcriptions: [
                        TranscriptionBlock(
                            repository: "⟨transcription repository⟩",
                            paths: ["⟨transcription path⟩"],
                            ranges: ["⟨transcription path⟩": [LineRange(start: 10, end: 20)]],
                            symbol: "⟨transcription symbol⟩",
                            mainlineCommit: "⟨transcription commit⟩",
                            content: "⟨transcription content⟩",
                            contentHash: "⟨content hash⟩",
                            authorSupplied: true,
                            authorSuppliedNight: NightStart(rawValue: "9999-12-31")
                        )
                    ]
                ),
                definitionOfDone: [
                    DoDClause(
                        id: "⟨clause id⟩",
                        text: "⟨clause text⟩",
                        citation: SpecCitation("⟨epic⟩/⟨story⟩")
                    )
                ],
                repository: InstructionRepository(
                    repo: repo,
                    worktreePath: "⟨worktree path⟩",
                    featureBranch: "⟨feature branch⟩",
                    check: .command("⟨check command⟩")
                ),
                route: Route(cli: "⟨cli⟩", model: "⟨model⟩", effort: "⟨effort⟩")!,
                payloads: InstructionPayloads(
                    roundFeedback: [
                        RoundFeedback(
                            round: 99,
                            lens: lens,
                            verdict: "⟨round verdict⟩",
                            requestedChanges: "⟨requested changes⟩",
                            judgedCommit: "⟨judged commit⟩"
                        )
                    ]
                ),
                commitMessage: nil,
                specCommit: nil,
                passTimeoutMinutes: nil,
                laneStack: LaneStackContext(
                    baseCommit: "⟨base commit⟩",
                    judgedCommit: "⟨judged commit⟩",
                    completedEarlierCards: [
                        LaneCompletedCard(key: "⟨earlier card key⟩", title: "⟨earlier card title⟩")
                    ]
                )
            )
        }

        let candidates = [
            "⟨work card key⟩",
            "⟨work card title⟩",
            "⟨work card description⟩",
            "⟨architectural brief prose⟩",
            "⟨transcription repository⟩",
            "⟨transcription path⟩",
            "lines 10–20",
            "⟨transcription symbol⟩",
            "⟨transcription commit⟩",
            "9999-12-31",
            "⟨transcription content⟩",
            "⟨clause id⟩",
            "⟨clause text⟩",
            "⟨epic⟩/⟨story⟩",
            "⟨repo name⟩",
            "backend",
            "⟨worktree path⟩",
            "⟨feature branch⟩",
            "⟨check command⟩",
            "⟨base commit⟩",
            "⟨judged commit⟩",
            "⟨earlier card key⟩",
            "⟨earlier card title⟩",
            "Round 99",
            "review",
            "check",
            "⟨round verdict⟩",
            "⟨requested changes⟩"
        ]

        let reviewVariant = makeVariant(
            name: "Review lens",
            template: makeInstruction(.review).render(),
            candidatePlaceholders: candidates
        )
        let checkVariant = makeVariant(
            name: "Check lens",
            template: makeInstruction(.check).render(),
            candidatePlaceholders: candidates
        )

        return PromptCatalogEntry(
            family: .reviewer,
            title: "Reviewer",
            purpose: "Judges a Work Card's committed changes against its Definition of Done and repository Checks.",
            defaultVersion: PromptFamily.reviewer.defaultVersion,
            acceptsProjectInstructions: PromptFamily.reviewer.acceptsProjectInstructions,
            variants: [reviewVariant, checkVariant]
        )
    }

    static var verifierEntry: PromptCatalogEntry {
        let specRepo = Repo(name: "⟨specification repository⟩", path: "⟨specification path⟩", role: .spec)
        let instruction = VerificationInstruction(
            route: Route(cli: "⟨cli⟩", model: "⟨model⟩", effort: "⟨effort⟩")!,
            featureTitle: "⟨feature title⟩",
            clauses: [
                VerificationClause(
                    issueID: "⟨issue id⟩",
                    cid: "⟨clause id⟩",
                    text: "⟨clause text⟩",
                    location: "⟨spec citation location⟩"
                )
            ],
            specificationSource: .workingRepo(specRepo),
            repositories: [
                VerificationRepository(
                    name: "⟨repo name⟩",
                    directory: "⟨repo directory⟩",
                    featureBranch: "⟨feature branch⟩",
                    checkResults: [
                        VerificationCheckResult(
                            command: "⟨check command⟩",
                            judgedCommit: "⟨judged commit⟩",
                            exitStatus: 0
                        )
                    ],
                    checkDeclaredNone: true
                )
            ]
        )
        let candidates = [
            "⟨feature title⟩",
            "⟨specification repository⟩",
            "⟨specification path⟩",
            "⟨issue id⟩",
            "⟨clause id⟩",
            "⟨clause text⟩",
            "⟨spec citation location⟩",
            "⟨repo name⟩",
            "⟨repo directory⟩",
            "⟨feature branch⟩",
            "⟨check command⟩",
            "⟨judged commit⟩",
            "0"
        ]
        let variant = makeVariant(name: "Default", template: instruction.render(), candidatePlaceholders: candidates)
        return PromptCatalogEntry(
            family: .verifier,
            title: "Verifier",
            purpose: "Verifies a completed Feature clause by clause against "
                + "the specification source and recorded Checks.",
            defaultVersion: PromptFamily.verifier.defaultVersion,
            acceptsProjectInstructions: PromptFamily.verifier.acceptsProjectInstructions,
            variants: [variant]
        )
    }
}
