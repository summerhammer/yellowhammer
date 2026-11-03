import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// feature-authoring/select-the-next-feature#adopted-repository (OQ195 item 2;
// Lane-less Repository Checkout Ruling 2026-11-02):
// A Feature's selected repositories always include the repository of every Work Card it adopts.
// When the selection leaves one out, the engine adds it before the Repo Dependency and release-gate
// checks run; the selection is not refused. That repository then has a recorded base commit and,
// if its lane pushes nothing, the No-Pushed-Branch Outcome.

private struct ScriptedReleaseGate: ReleaseGate {
    let held: [HeldConsumer]

    func heldConsumers(_ context: ActContext) async throws -> [HeldConsumer] { held }
}

@Suite("Feature selection with adopted Work Card repositories (OQ195 item 2)")
struct FeatureSelectionAdoptedRepositoryTests {
    @Test("An adopted Card whose repository the selector omitted is added to selected repositories")
    func adoptedCardRepositoryIsAddedToSelection() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let repositories = selectionRepositories()
        let (_, cycleID) = try insertFeatureSelectionAdoptionFixture(journal, closedFeatureIssueID: "OLD-1")
        try insertFeatureSelectionAdoptionCard(
            journal, cycleID: cycleID, issueID: "MOB-1", repository: "mobile", order: 1
        )
        // Selector names only "backend", but adopts "MOB-1" (which is in "mobile")
        let selected = SelectedFeature(
            name: try #require(FeatureName(rawValue: "FEAT-1")),
            reasoning: "Omits mobile.",
            sequence: nil,
            repositories: ["backend"],
            adoptedCardIssueIDs: ["MOB-1"]
        )
        let selector = ScriptedFeatureSelector(outcome: .selected(selected))
        let transaction = ScriptedSelectedFeatureAuthoring()
        let selection = FeatureSelection(selector: selector, transaction: transaction)
        let (context, _) = try makeSelectionContext(journal, repositories: repositories)

        let outcome = try await selection.selectAndAuthor(context)

        #expect(outcome == .authored)
        #expect(transaction.callCount == 1)
        let handed = try #require(transaction.lastSelection)
        #expect(handed.repositories == ["backend", "mobile"])
        #expect(handed.adoptedCardIssueIDs == ["MOB-1"])
        #expect(handed.engineAddedRepositories == ["mobile"])

        let events = try journal.events()
        let event = try #require(events.first { $0.type == .featureSelected })
        guard case .featureSelected(let payload) = event.event else {
            Issue.record("expected featureSelected")
            return
        }
        #expect(payload.name == "FEAT-1")
        #expect(payload.repositories == ["backend", "mobile"])
        #expect(payload.adoptedCardIssueIDs == ["MOB-1"])
        #expect(payload.engineAddedRepositories == ["mobile"])
    }

    @Test("A halt repair's selection, already widened, still names the repository the engine added")
    func repairedSelectionKeepsEngineAddedRepository() throws {
        // On halt repair the selection comes back from the checkpoint with the widened repositories.
        let checkpointed = SelectedFeature(
            name: try #require(FeatureName(rawValue: "FEAT-1")), reasoning: "Omits mobile.", sequence: nil,
            repositories: ["backend", "mobile"], adoptedCardIssueIDs: ["MOB-1"],
            engineAddedRepositories: ["mobile"]
        )
        let candidates = [AdoptionCandidate(issueID: "MOB-1", repository: "mobile")]

        let resolved = FeatureSelection.resolveAdoptedRepositories(selected: checkpointed, candidates: candidates)

        #expect(resolved.repositories == ["backend", "mobile"])
        #expect(resolved.engineAdded == ["mobile"])
    }

    @Test("A selection that already lists the adopted Card's repository records no engine-added repository")
    func selectorListedRepositoryIsNotEngineAdded() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (_, cycleID) = try insertFeatureSelectionAdoptionFixture(journal, closedFeatureIssueID: "OLD-1")
        try insertFeatureSelectionAdoptionCard(
            journal, cycleID: cycleID, issueID: "MOB-1", repository: "mobile", order: 1
        )
        let selected = SelectedFeature(
            name: try #require(FeatureName(rawValue: "FEAT-1")),
            reasoning: "Lists mobile itself.",
            sequence: nil,
            repositories: ["backend", "mobile"],
            adoptedCardIssueIDs: ["MOB-1"]
        )
        let transaction = ScriptedSelectedFeatureAuthoring()
        let selection = FeatureSelection(
            selector: ScriptedFeatureSelector(outcome: .selected(selected)), transaction: transaction
        )
        let (context, _) = try makeSelectionContext(journal, repositories: selectionRepositories())

        let outcome = try await selection.selectAndAuthor(context)

        #expect(outcome == .authored)
        #expect(try #require(transaction.lastSelection).engineAddedRepositories == [])
        let event = try #require(try journal.events().first { $0.type == .featureSelected })
        guard case .featureSelected(let payload) = event.event else {
            Issue.record("expected featureSelected")
            return
        }
        #expect(payload.repositories == ["backend", "mobile"])
        #expect(payload.engineAddedRepositories == [])
    }

    @Test("A repository added only through an adopted Card triggers the Repo Dependency Authoring Halt")
    func adoptedRepositoryTriggersRepoDependencyHalt() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let transaction = ScriptedSelectedFeatureAuthoring()
        let (_, cycleID) = try insertFeatureSelectionAdoptionFixture(journal, closedFeatureIssueID: "OLD-1")
        try insertFeatureSelectionAdoptionCard(
            journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", order: 1
        )
        // The selector names only "contracts", but adopts "BACK-1" (in "backend", which consumes "contracts")
        let selected = SelectedFeature(
            name: try #require(FeatureName(rawValue: "FEAT-1")),
            reasoning: "Only names contracts directly.",
            sequence: nil,
            repositories: ["contracts"],
            adoptedCardIssueIDs: ["BACK-1"]
        )
        let selector = ScriptedFeatureSelector(outcome: .selected(selected))
        let selection = FeatureSelection(selector: selector, transaction: transaction)
        let repos = ProjectRepositories(
            workingRepos: [
                Repo(
                    name: "backend", path: "/repos/backend", role: .backend,
                    consumes: [RepoDependency(producer: "contracts", via: .tag)]
                ),
                Repo(name: "mobile", path: "/repos/mobile", role: .mobile),
                Repo(name: "contracts", path: "/repos/contracts", role: .backend)
            ],
            specSource: SpecSource(path: "/repos/spec")
        )
        let (context, _) = try makeSelectionContext(journal, repositories: repos, boards: boards)

        let outcome = try await selection.selectAndAuthor(context)

        #expect(outcome == .halted)
        #expect(transaction.callCount == 0)
        let events = try journal.events()
        #expect(!events.contains { $0.type == .featureSelected })
        let event = try #require(events.first { $0.type == .featureAuthoringHalted })
        guard case .featureAuthoringHalted(let name, let kind, let detail) = event.event else {
            Issue.record("expected featureAuthoringHalted")
            return
        }
        #expect(name == "FEAT-1")
        #expect(kind == "feature-spans-repo-dependency")
        #expect(detail == "backend->contracts(tag)")

        let featureName = try #require(FeatureName(rawValue: "FEAT-1"))
        let halts = try journal.authoringHalts(feature: featureName)
        let halt = try #require(halts.first)
        let checkpoint = try #require(try journal.authoringHaltCheckpoint(haltID: halt.id))
        #expect(checkpoint.selection?.repositories == ["backend", "contracts"])
        #expect(checkpoint.selection?.adoptedCardIssueIDs == ["BACK-1"])
        // The engine added "backend" (the selector named only "contracts"); the halt checkpoint keeps that.
        #expect(checkpoint.selection?.engineAddedRepositories == ["backend"])
    }

    @Test("A repository added only through an adopted Card triggers the release-gate hold")
    func adoptedRepositoryTriggersReleaseGateHold() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let transaction = ScriptedSelectedFeatureAuthoring()
        let (_, cycleID) = try insertFeatureSelectionAdoptionFixture(journal, closedFeatureIssueID: "OLD-1")
        try insertFeatureSelectionAdoptionCard(
            journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", order: 1
        )
        // Selector names only "mobile", but adopts "BACK-1" in "backend" which is held
        let selected = SelectedFeature(
            name: try #require(FeatureName(rawValue: "FEAT-1")),
            reasoning: "Only names mobile directly.",
            sequence: nil,
            repositories: ["mobile"],
            adoptedCardIssueIDs: ["BACK-1"]
        )
        let selector = ScriptedFeatureSelector(outcome: .selected(selected))
        let heldBackend = HeldConsumer(
            consumer: "backend", producer: "contracts", producerFeature: "FEAT-K",
            producerFeatureIssueID: "FEAT-K", hold: .awaitingRelease
        )
        let gate = ScriptedReleaseGate(held: [heldBackend])
        let selection = FeatureSelection(selector: selector, transaction: transaction, releaseGate: gate)
        let repos = ProjectRepositories(
            workingRepos: [
                Repo(
                    name: "backend", path: "/repos/backend", role: .backend,
                    consumes: [RepoDependency(producer: "contracts", via: .tag)]
                ),
                Repo(name: "mobile", path: "/repos/mobile", role: .mobile),
                Repo(name: "contracts", path: "/repos/contracts", role: .backend)
            ],
            specSource: SpecSource(path: "/repos/spec")
        )
        let (context, _) = try makeSelectionContext(journal, repositories: repos, boards: boards)

        let outcome = try await selection.selectAndAuthor(context)

        #expect(outcome == .releaseGateHeld)
        #expect(transaction.callCount == 0)
        let events = try journal.events()
        #expect(!events.contains { $0.type == .featureSelected })
        #expect(events.filter { $0.type == .authoringReleaseGateHeld }.map(\.event) == [
            .authoringReleaseGateHeld(
                featureName: "FEAT-1", consumer: "backend", producer: "contracts",
                producerFeatureIssueID: "FEAT-K", hold: .awaitingRelease
            )
        ])
    }

    private func seedAdoptedCard(_ rig: AuthoringRig, issueID: String, repository: String) async throws {
        let oldFeature = await rig.boards.writing.seed(issue: "FEAT-OLD", description: nil)
        let card = await rig.boards.writing.seed(issue: issueID, description: nil)
        _ = try await rig.boards.writing.updateIssue(card, BoardIssueChange(parent: .set(oldFeature)))
        let (_, oldCycleID) = try insertFeatureSelectionAdoptionFixture(rig.journal, closedFeatureIssueID: "FEAT-OLD")
        let rowID = try insertFeatureSelectionAdoptionCard(
            rig.journal, cycleID: oldCycleID, issueID: issueID, repository: repository, order: 3
        )
        try rig.journal.write { db in
            try db.execute(
                sql: """
                UPDATE card SET failed_adoptions = 2, unanswered_nights = 1, budget_epoch = 4,
                block_reason = 'reply overdue' WHERE id = ?
                """,
                arguments: [rowID]
            )
        }
    }

    @Test("Recorded base and no Verification fault for repository added through adoption")
    func recordedBaseAndNoVerificationFaultForAdoptedRepository() async throws {
        // Selector selects "FEAT-1" with repository ["backend"] and adopts "CARD-OLD"
        let selectedFeature = SelectedFeature(
            name: try #require(FeatureName(rawValue: "FEAT-1")),
            reasoning: "Omits mobile.",
            sequence: nil,
            repositories: ["backend"],
            adoptedCardIssueIDs: ["CARD-OLD"]
        )
        let selector = ScriptedFeatureSelector(outcome: .selected(selectedFeature))
        let rig = try await AuthoringRig(selector: selector)
        try await seedAdoptedCard(rig, issueID: "CARD-OLD", repository: "mobile")

        let context = try rig.context()
        let outcome = try await rig.run(context)
        #expect(outcome == .authored)

        let (feature, cycleID) = try #require(try rig.journal.inFlightFeature())
        let touched = try rig.journal.touchedRepositories(featureID: feature.id)
        #expect(touched.contains("mobile"))

        let bases = try rig.journal.featureBases(featureID: feature.id)
        let mobileBase = try #require(bases.first { $0.repository == "mobile" })
        let expectedCommit = try #require(selectionMainlines()["mobile"]?.commit)
        #expect(mobileBase.baseCommit == expectedCommit)

        // Record a noPushedBranchOutcome for the added repository
        try rig.journal.append(
            .noPushedBranchOutcome(cycleID: cycleID, featureIssueID: feature.issueID, repository: "mobile"),
            act: .land, runID: context.runID, nightID: context.night.id
        )

        let noPushed = try rig.journal.noPushedBranchRepositories(featureID: feature.id)
        #expect(noPushed == ["mobile"])

        // JudgedCheckoutPreparation.plan gives mobile a judged checkout marked noPushedBranch without faulting
        let landActContext = ActContext(
            act: .land, mode: .real, trigger: context.trigger, runID: context.runID, journal: rig.journal,
            night: context.night, outbox: context.outbox, board: context.board, mainlines: context.mainlines,
            workspace: context.workspace, repositories: context.repositories, featureBases: context.featureBases
        )
        let featureContext = LandActFeatureContext(act: landActContext, feature: feature, cycleID: cycleID)
        let preparation = JudgedCheckoutPreparation(
            directory: FileManager.default.temporaryDirectory.appending(
                component: "yh-test-adopted-\(UUID().uuidString)", directoryHint: .isDirectory
            )
        )
        let plan = try await preparation.plan(featureContext, repositories: ["mobile"])
        let judged = try #require(plan.judgedCheckouts.first { $0.repository == "mobile" })
        #expect(judged.commit == expectedCommit)
        #expect(judged.noPushedBranch == true)
    }

    @Test("An adopted Card in a repository outside this Project triggers contractOutsideProject halt")
    func adoptedCardOutsideProjectHalts() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let transaction = ScriptedSelectedFeatureAuthoring()
        let (_, cycleID) = try insertFeatureSelectionAdoptionFixture(journal, closedFeatureIssueID: "OLD-1")
        try insertFeatureSelectionAdoptionCard(
            journal, cycleID: cycleID, issueID: "UNKNOWN-1", repository: "unknown-repo", order: 1
        )
        let selected = SelectedFeature(
            name: try #require(FeatureName(rawValue: "FEAT-1")),
            reasoning: "Adopts card in unknown repo.",
            sequence: nil,
            repositories: ["backend"],
            adoptedCardIssueIDs: ["UNKNOWN-1"]
        )
        let selector = ScriptedFeatureSelector(outcome: .selected(selected))
        let selection = FeatureSelection(selector: selector, transaction: transaction)
        let (context, _) = try makeSelectionContext(journal, repositories: selectionRepositories(), boards: boards)

        let outcome = try await selection.selectAndAuthor(context)

        #expect(outcome == .halted)
        #expect(transaction.callCount == 0)
        let events = try journal.events()
        #expect(!events.contains { $0.type == .featureSelected })
        let event = try #require(events.first { $0.type == .featureAuthoringHalted })
        guard case .featureAuthoringHalted(let name, let kind, let detail) = event.event else {
            Issue.record("expected featureAuthoringHalted")
            return
        }
        #expect(name == "FEAT-1")
        #expect(kind == "contract-outside-project")
        #expect(detail == "unknown-repo")
    }
}
