import Foundation

// These builders are declarative prompt fixtures; keep each instruction and its placeholder list together.
// swiftlint:disable function_body_length
extension PromptCatalog {
    /// Builds the entry through the real renderer, composed with the Project's instructions when given.
    static func selectionEntry(_ projectInstructions: String?) -> PromptCatalogEntry {
        let repo = Repo(
            name: "⟨repo name⟩",
            path: "⟨repo path⟩",
            role: .backend,
            consumes: [RepoDependency(producer: "⟨producer repo⟩", via: .tag)]
        )
        let specRepo = Repo(name: "⟨specification repository⟩", path: "⟨specification path⟩", role: .spec)
        let instruction = AuthoringInstruction(
            pass: .selection,
            route: Route(cli: "⟨cli⟩", model: "⟨model⟩", effort: "⟨effort⟩")!,
            specificationSource: .workingRepo(specRepo),
            specificationMainline: ResolvedMainline(
                repository: "⟨specification repository⟩",
                defaultBranch: "main",
                ref: "⟨specification ref⟩",
                commit: "⟨specification commit⟩"
            ),
            repos: [repo],
            mainlines: ResolvedMainlines(workingRepos: [
                repo.name: ResolvedMainline(
                    repository: repo.name,
                    defaultBranch: "main",
                    ref: "refs/yellowhammer/landed/⟨landed feature⟩",
                    commit: "⟨mainline commit⟩"
                )
            ]),
            namedFeature: FeatureName(rawValue: "⟨named feature⟩"),
            adoptionCandidates: [
                AdoptionCandidate(
                    issueID: "⟨adopted issue id⟩",
                    repository: "⟨repo name⟩",
                    title: "⟨adopted issue title⟩",
                    blockReason: "⟨block reason⟩"
                )
            ],
            refusedThisNight: [FeatureName(rawValue: "⟨refused feature⟩")!],
            heldConsumers: [
                HeldConsumer(
                    consumer: "⟨held consumer repo⟩",
                    producer: "⟨producer repo⟩",
                    producerFeature: "⟨producer feature⟩",
                    hold: .awaitingRelease
                )
            ],
            selectedFeature: nil,
            descriptionRoom: nil,
            earlierRejections: ["⟨earlier rejection⟩"],
            boardState: SelectionBoardState(
                features: [
                    SelectionBoardState.AuthoredFeature(
                        name: "⟨feature name⟩",
                        identifier: "⟨feature identifier⟩",
                        outcome: "⟨feature outcome⟩"
                    )
                ],
                waitingCards: [
                    SelectionBoardState.WaitingCard(
                        identifier: "⟨waiting card identifier⟩",
                        title: "⟨waiting card title⟩",
                        repository: "⟨repo name⟩",
                        reason: "⟨waiting reason⟩"
                    )
                ],
                unmergedFeatures: [
                    SelectionBoardState.UnmergedFeature(
                        name: "⟨unmerged feature name⟩",
                        identifier: "⟨unmerged feature identifier⟩",
                        touchedRepositories: ["⟨repo name⟩"],
                        unmergedBranches: [
                            SelectionBoardState.UnmergedBranch(
                                repository: "⟨repo name⟩",
                                branch: "⟨unmerged branch⟩"
                            )
                        ]
                    )
                ]
            )
        )
        let candidates = [
            "⟨specification repository⟩",
            "⟨specification path⟩",
            "⟨specification commit⟩",
            "⟨repo name⟩",
            "backend",
            "⟨repo path⟩",
            "⟨mainline commit⟩",
            "⟨landed feature⟩",
            "tag",
            "⟨producer repo⟩",
            "⟨held consumer repo⟩",
            "⟨producer feature⟩",
            "⟨named feature⟩",
            "⟨adopted issue id⟩",
            "⟨adopted issue title⟩",
            "⟨block reason⟩",
            "⟨feature name⟩",
            "⟨feature identifier⟩",
            "⟨feature outcome⟩",
            "⟨unmerged feature name⟩",
            "⟨unmerged feature identifier⟩",
            "⟨unmerged branch⟩",
            "⟨waiting card identifier⟩",
            "⟨waiting card title⟩",
            "⟨waiting reason⟩",
            "⟨refused feature⟩",
            "⟨earlier rejection⟩"
        ]
        let variant = makeVariant(
            name: "Default",
            template: instruction.render(projectInstructions: projectInstructions),
            shippedTemplate: instruction.render(),
            candidatePlaceholders: candidates
        )
        return PromptCatalogEntry(
            family: .selection,
            title: "Selection",
            purpose: "Selects the next Feature to author from the specification, "
                + "respecting dependency order and board state.",
            defaultVersion: PromptFamily.selection.defaultVersion,
            acceptsProjectInstructions: PromptFamily.selection.acceptsProjectInstructions,
            variants: [variant]
        )
    }

    /// Builds the entry through the real renderer, composed with the Project's instructions when given.
    static func breakdownEntry(_ projectInstructions: String?) -> PromptCatalogEntry {
        let repo = Repo(name: "⟨repo name⟩", path: "⟨repo path⟩", role: .backend)
        let specRepo = Repo(name: "⟨specification repository⟩", path: "⟨specification path⟩", role: .spec)
        let instruction = AuthoringInstruction(
            pass: .breakdown,
            route: Route(cli: "⟨cli⟩", model: "⟨model⟩", effort: "⟨effort⟩")!,
            specificationSource: .workingRepo(specRepo),
            specificationMainline: ResolvedMainline(
                repository: "⟨specification repository⟩",
                defaultBranch: "main",
                ref: "⟨specification ref⟩",
                commit: "⟨specification commit⟩"
            ),
            repos: [repo],
            mainlines: ResolvedMainlines(workingRepos: [
                repo.name: ResolvedMainline(
                    repository: repo.name,
                    defaultBranch: "main",
                    ref: "⟨mainline ref⟩",
                    commit: "⟨mainline commit⟩"
                )
            ]),
            namedFeature: nil,
            adoptionCandidates: [],
            refusedThisNight: [],
            heldConsumers: [],
            selectedFeature: SelectedFeature(
                name: FeatureName(rawValue: "⟨selected feature name⟩")!,
                reasoning: "⟨selected feature reasoning⟩",
                sequence: FeatureSequence(
                    precededBy: "⟨preceded by feature⟩",
                    followedBy: "⟨followed by feature⟩",
                    seam: "⟨backward compatible seam⟩"
                ),
                repositories: ["⟨repo name⟩"],
                adoptedCardIssueIDs: ["⟨adopted card id⟩"]
            ),
            descriptionRoom: try? BreakdownDescriptionRoom(
                budget: DescriptionBudget(
                    configured: 99999,
                    limit: BoardDescriptionLimit(maximum: 99999, unit: .characters)
                ),
                rooms: [BreakdownDescriptionRoom.RepositoryRoom(repository: "⟨repo name⟩", room: 88888)],
                clauseOverhead: 111,
                referenceOverhead: 333,
                pathOverhead: 222
            ),
            earlierRejections: ["⟨earlier rejection⟩"],
            boardState: nil
        )
        let candidates = [
            "⟨specification repository⟩",
            "⟨specification path⟩",
            "⟨specification commit⟩",
            "⟨repo name⟩",
            "backend",
            "⟨repo path⟩",
            "⟨mainline commit⟩",
            "⟨selected feature name⟩",
            "⟨selected feature reasoning⟩",
            "⟨preceded by feature⟩",
            "⟨followed by feature⟩",
            "⟨backward compatible seam⟩",
            "⟨adopted card id⟩",
            "99999",
            "characters",
            "333",
            "222",
            "111",
            "88888",
            "⟨earlier rejection⟩"
        ]
        let variant = makeVariant(
            name: "Default",
            template: instruction.render(projectInstructions: projectInstructions),
            shippedTemplate: instruction.render(),
            candidatePlaceholders: candidates
        )
        return PromptCatalogEntry(
            family: .breakdown,
            title: "Breakdown",
            purpose: "Drafts a selected Feature's Work Cards, Definition of Done, and contract boundaries.",
            defaultVersion: PromptFamily.breakdown.defaultVersion,
            acceptsProjectInstructions: PromptFamily.breakdown.acceptsProjectInstructions,
            variants: [variant]
        )
    }

    /// Builds the entry through the real renderer, composed with the Project's instructions when given.
    static func architectEntry(_ projectInstructions: String?) -> PromptCatalogEntry {
        let repo = Repo(name: "⟨repo name⟩", path: "⟨repo path⟩", role: .backend)
        let instruction = Instruction(
            pass: .architect,
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
            payloads: .none,
            commitMessage: nil,
            specCommit: nil,
            passTimeoutMinutes: 999,
            laneStack: LaneStackContext(
                baseCommit: "⟨base commit⟩",
                completedEarlierCards: [
                    LaneCompletedCard(key: "⟨earlier card key⟩", title: "⟨earlier card title⟩")
                ]
            )
        )
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
            "⟨earlier card key⟩",
            "⟨earlier card title⟩",
            "999"
        ]
        let variant = makeVariant(
            name: "Default",
            template: instruction.render(projectInstructions: projectInstructions),
            shippedTemplate: instruction.render(),
            candidatePlaceholders: candidates
        )
        return PromptCatalogEntry(
            family: .architect,
            title: "Architect",
            purpose: "Plans a Work Card's implementation approach and verifies cross-repository boundaries.",
            defaultVersion: PromptFamily.architect.defaultVersion,
            acceptsProjectInstructions: PromptFamily.architect.acceptsProjectInstructions,
            variants: [variant]
        )
    }
}
// swiftlint:enable function_body_length
