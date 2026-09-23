import Domain
@testable import Engine
import Foundation
@testable import Journal
@testable import Repositories
import Testing

// roadmap P11.5: fixtures shared by AdoptionRevalidationTests.swift, split out to keep that suite's
// type body under the length limit.

extension AdoptionRevalidationTests {
    struct SeededCandidate {
        let oldFeature: BoardObjectID
        let card: BoardObjectID
        let cardRowID: Int64
    }

    /// A fresh author Act context, mirroring `RefusalLifecycleTests`' own — `AuthoringRig` fixes its
    /// Night, and these tests need more than one.
    func context(
        _ journal: JournalStore, nightStart: String, boards: NightCardTestBoards, previous: RunID? = nil,
        repositories: ProjectRepositories? = nil, mainlines: ResolvedMainlines? = nil
    ) throws -> (context: ActContext, runID: RunID) {
        if let previous {
            try journal.releaseActLease(runID: previous)
        }
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .author, runID: runID, mode: .rehearsal) else {
            throw JournalError.actLeaseLost(runID: runID, holder: nil)
        }
        let opening = try journal.openNight(
            nightStart: try #require(NightStart(rawValue: nightStart)), mode: .rehearsal, act: .author, runID: runID
        )
        let outbox = Outbox(
            journal: journal, board: boards.writing, runID: runID, act: .author, nightID: opening.night.id
        )
        let actBoard = ActBoard(
            reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning
        )
        let ctx = ActContext(
            act: .author, mode: .rehearsal, trigger: .scheduled, runID: runID, journal: journal,
            night: opening.night, outbox: outbox, board: actBoard, mainlines: mainlines ?? selectionMainlines(),
            workspace: nil, repositories: repositories ?? selectionRepositories()
        )
        return (ctx, runID)
    }

    /// A Blocked adoption candidate in an archived Cycle, carrying one Transcription Block, whose board
    /// issue hangs under the old (closed) Feature Issue.
    func seedCandidate(
        _ journal: JournalStore, boards: NightCardTestBoards, issueID: String = "CARD-OLD",
        mainlineCommit: String = String(repeating: "a", count: 40)
    ) async throws -> SeededCandidate {
        let oldFeature = await boards.writing.seed(issue: "FEAT-OLD", description: nil)
        // A fenced description, like every real Card starts with (`AuthoringPlanner.cardDescription`),
        // so the Managed Block rewrite this suite exercises has a fence to splice into.
        let card = await boards.writing.seed(
            issue: issueID, description: ManagedBlockFence.initialDescription(rendered: "")
        )
        _ = try await boards.writing.updateIssue(card, BoardIssueChange(parent: .set(oldFeature)))
        let (_, cycleID) = try insertFeatureSelectionAdoptionFixture(journal, closedFeatureIssueID: "FEAT-OLD")
        let rowID = try insertFeatureSelectionAdoptionCard(
            journal, cycleID: cycleID, issueID: issueID, repository: "backend", order: 1
        )
        try journal.recordTranscriptionBlocks(cardID: rowID, [
            TranscriptionBlock(
                repository: "backend", paths: ["contract.swift"], mainlineCommit: mainlineCommit,
                content: "protocol Contract {}", contentHash: "hash", authorSupplied: false
            )
        ])
        return SeededCandidate(oldFeature: oldFeature, card: card, cardRowID: rowID)
    }

    func selection(
        _ transaction: AuthoringTransaction, operatorIdentity: OperatorIdentity = .none
    ) throws -> FeatureSelection {
        FeatureSelection(
            selector: ScriptedFeatureSelector(outcome: .selected(try authoringSelection(adopting: ["CARD-OLD"]))),
            transaction: transaction, operatorIdentity: operatorIdentity
        )
    }

    /// The two-repository, three-Card breakdown every scenario but the sole-content one drafts, beside
    /// whichever Card the selection tries to adopt.
    func threeCardBreakdown() throws -> FeatureBreakdown {
        try authoringBreakdown(backendTitles: ["Backend one"], mobileTitles: ["Mobile one"])
    }

    /// An `AuthoringTransaction` scripted with `threeCardBreakdown()` and the given provenance.
    func transaction(
        provenance: any ProvenanceTesting, operatorIdentity: OperatorIdentity = .none
    ) throws -> AuthoringTransaction {
        AuthoringTransaction(
            drafting: ScriptedBreakdown(try threeCardBreakdown()), citations: FakeCitationResolver(),
            transcribing: FakeContractTranscriber(), provenance: provenance, operatorIdentity: operatorIdentity
        )
    }
}

/// A throwaway local git repository, for the one real-provenance test in this suite — the rest use
/// `FakeProvenanceTester`. Minimal on purpose: `git init`, one commit, one more commit that moves the
/// recorded path.
struct AdoptionGitFixture: ~Copyable {
    let url: URL
    private let git = GitRunner()

    init(name: String = UUID().uuidString) {
        url = FileManager.default.temporaryDirectory.appending(component: "yh-adoption-git-\(name)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    var path: String { url.path(percentEncoded: false) }

    func initRepo() async {
        _ = await git.run(["-C", path, "init", "--initial-branch=main"])
        _ = await git.run(["-C", path, "config", "user.name", "Yellowhammer Test"])
        _ = await git.run(["-C", path, "config", "user.email", "test@yellowhammer.local"])
        _ = await git.run(["-C", path, "config", "commit.gpgsign", "false"])
    }

    @discardableResult
    func commit(filename: String, content: String, message: String) async throws -> String {
        try content.write(to: url.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        _ = await git.run(["-C", path, "add", "."])
        _ = await git.run(["-C", path, "commit", "-m", message])
        let result = await git.run(["-C", path, "rev-parse", "HEAD"])
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
