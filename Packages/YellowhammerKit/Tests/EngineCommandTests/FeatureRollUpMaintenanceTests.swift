import Domain
@testable import Engine
import Foundation
import GRDB
@testable import Journal
import Testing

// The Feature Roll-up's Managed Block maintenance (roadmap P12.3; spec: board-projection/maintain-the-
// managed-block, second story): rendered from the Journal, hashed, and conditionally posted through
// the Outbox — modelled on ManagedBlockMaintenanceTests.swift, but for the Feature Issue, which needs
// no Card Lease. `OutboxJournalFixture` is created inside every @Test, never in a helper. Fixtures
// (``RollUpWorld``, row inserts) live in FeatureRollUpMaintenanceFixtures.swift. The zero-Card standing
// and `maintainAll` tests live in FeatureRollUpMaintenanceZeroCardTests.swift, split out for the
// type/file length limits.

@Suite("Feature Roll-up maintenance (P12.3)")
struct FeatureRollUpMaintenanceTests {
    // MARK: - Hash-skip

    @Test("The first maintain posts; an unchanged repost is skipped, with no new board or Outbox activity")
    func firstPostsSecondSkips() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try makeRollUpWorld(journal)
        await world.board.seed(issue: "FEAT-1", description: ManagedBlockFence.initialDescription(rendered: ""))
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-1", branch: "yh-proj-feat", repositories: ["backend"]
        )
        let cycleID = try gateCycleID(journal, featureID: featureID)
        try insertRollUpCard(
            journal, cycleID: cycleID, .init(issueID: "BACK-1", repository: "backend", order: 1, state: .done)
        )
        let feature = try #require(try journal.feature(issueID: "FEAT-1"))
        let maintenance = FeatureRollUpMaintenance(journal: journal, outbox: world.outbox)

        let first = try await maintenance.maintain(feature: feature, cycleID: cycleID)
        guard case .posted(let hash, let delivery) = first else {
            Issue.record("expected posted, got \(first)")
            return
        }
        #expect(delivery.outcome == .applied(nil))
        let description = try #require(await world.board.issue(BoardObjectID(rawValue: "FEAT-1"))?.description)
        #expect(description.contains("running · 1 of 1 Cards landed · all on track"))
        #expect(try journal.managedBlockLastPostedHash(issueID: "FEAT-1") == hash)

        let updates = await world.board.updateCalls
        let pending = try journal.pendingOutboxEntries().count

        let second = try await maintenance.maintain(feature: feature, cycleID: cycleID)
        #expect(second == .skipped(hash: hash))
        #expect(await world.board.updateCalls == updates)
        #expect(try journal.pendingOutboxEntries().count == pending)
    }

    // MARK: - Reposts on each axis

    @Test("Lane completion alone reposts: the Cycle landing moves the running half to the closed half")
    func repostsOnLaneCompletion() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try makeRollUpWorld(journal)
        await world.board.seed(issue: "FEAT-1", description: ManagedBlockFence.initialDescription(rendered: ""))
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-1", branch: "yh-proj-feat", repositories: ["backend"]
        )
        let cycleID = try gateCycleID(journal, featureID: featureID)
        try insertRollUpCard(
            journal, cycleID: cycleID, .init(issueID: "BACK-1", repository: "backend", order: 1, state: .done)
        )
        let feature = try #require(try journal.feature(issueID: "FEAT-1"))
        let maintenance = FeatureRollUpMaintenance(journal: journal, outbox: world.outbox)

        let before = try await maintenance.maintain(feature: feature, cycleID: cycleID)
        guard case .posted(let beforeHash, _) = before else {
            Issue.record("expected posted, got \(before)")
            return
        }

        try journal.markCycleLanded(cycleID: cycleID, runID: world.runID)
        let after = try await maintenance.maintain(feature: feature, cycleID: cycleID)
        guard case .posted(let afterHash, _) = after else {
            Issue.record("expected posted, got \(after)")
            return
        }
        #expect(afterHash != beforeHash)
        let description = try #require(await world.board.issue(BoardObjectID(rawValue: "FEAT-1"))?.description)
        let expected = "partial landing · 1 of 1 Cards landed · 0 of 1 merged · verification not passed"
        #expect(description.contains(expected))
    }

    @Test("Only the repository whose Worktree actually pushed is headed 'pushed' (issue #161 part 2)")
    func onlyPushedRepositoryReadsPushedInBlock() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try makeRollUpWorld(journal)
        await world.board.seed(issue: "FEAT-1", description: ManagedBlockFence.initialDescription(rendered: ""))
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-1", branch: "yh-proj-feat", repositories: ["backend", "mobile"]
        )
        let cycleID = try gateCycleID(journal, featureID: featureID)
        try insertRollUpCard(
            journal, cycleID: cycleID, .init(issueID: "BACK-1", repository: "backend", order: 1, state: .done)
        )
        try insertRollUpCard(
            journal, cycleID: cycleID, .init(issueID: "MOB-1", repository: "mobile", order: 1, state: .done)
        )
        // Only "backend" pushed; "mobile" landed (the Cycle landed) but its own push never happened —
        // a rehearsal Night, or a real lane whose push failed, looks like this too.
        let backendWorktree = try journal.recordWorktree(
            featureID: featureID, repository: "backend", worktreeID: "wt-backend", path: "/tmp/backend",
            runID: world.runID
        )
        try journal.recordWorktreePush(id: backendWorktree.id, commit: "deadbeef", runID: world.runID)
        _ = try journal.recordWorktree(
            featureID: featureID, repository: "mobile", worktreeID: "wt-mobile", path: "/tmp/mobile",
            runID: world.runID
        )
        try journal.markCycleLanded(cycleID: cycleID, runID: world.runID)
        let feature = try #require(try journal.feature(issueID: "FEAT-1"))
        let maintenance = FeatureRollUpMaintenance(journal: journal, outbox: world.outbox)

        _ = try await maintenance.maintain(feature: feature, cycleID: cycleID)

        let description = try #require(await world.board.issue(BoardObjectID(rawValue: "FEAT-1"))?.description)
        #expect(description.contains("#### `backend` — pushed"))
        #expect(description.contains("#### `mobile` — finished"))
    }

    @Test("Merged fraction alone reposts: 0 of 2 moves to 1 of 2 as ancestry is observed")
    func repostsOnMergedFraction() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try makeRollUpWorld(journal)
        await world.board.seed(issue: "FEAT-1", description: ManagedBlockFence.initialDescription(rendered: ""))
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-1", branch: "yh-proj-feat", repositories: ["backend", "frontend"], landed: true
        )
        let cycleID = try gateCycleID(journal, featureID: featureID)
        try insertRollUpCard(
            journal, cycleID: cycleID, .init(issueID: "BACK-1", repository: "backend", order: 1, state: .done)
        )
        let feature = try #require(try journal.feature(issueID: "FEAT-1"))
        let maintenance = FeatureRollUpMaintenance(journal: journal, outbox: world.outbox)

        let before = try await maintenance.maintain(feature: feature, cycleID: cycleID)
        guard case .posted(let beforeHash, _) = before else {
            Issue.record("expected posted, got \(before)")
            return
        }
        let beforeDescription = try #require(await world.board.issue(BoardObjectID(rawValue: "FEAT-1"))?.description)
        #expect(beforeDescription.contains("0 of 2 merged"))

        try journal.append(
            .predecessorAncestryObserved(
                featureIssueID: "FEAT-1", mergedRepositories: ["backend"], unmergedRepositories: ["frontend"]
            ),
            act: .build, runID: world.runID, nightID: world.night.id
        )
        let after = try await maintenance.maintain(feature: feature, cycleID: cycleID)
        guard case .posted(let afterHash, _) = after else {
            Issue.record("expected posted, got \(after)")
            return
        }
        #expect(afterHash != beforeHash)
        let afterDescription = try #require(await world.board.issue(BoardObjectID(rawValue: "FEAT-1"))?.description)
        #expect(afterDescription.contains("1 of 2 merged"))
    }

    @Test("A Mainline Conflict appearing alone reposts, beside the sentence, never inside it")
    func repostsOnMainlineConflict() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try makeRollUpWorld(journal)
        await world.board.seed(issue: "FEAT-1", description: ManagedBlockFence.initialDescription(rendered: ""))
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-1", branch: "yh-proj-feat", repositories: ["backend", "frontend"], landed: true
        )
        let cycleID = try gateCycleID(journal, featureID: featureID)
        try insertRollUpCard(
            journal, cycleID: cycleID, .init(issueID: "BACK-1", repository: "backend", order: 1, state: .done)
        )
        try journal.append(
            .predecessorAncestryObserved(
                featureIssueID: "FEAT-1", mergedRepositories: ["backend"], unmergedRepositories: ["frontend"]
            ),
            act: .build, runID: world.runID, nightID: world.night.id
        )
        let feature = try #require(try journal.feature(issueID: "FEAT-1"))
        let maintenance = FeatureRollUpMaintenance(journal: journal, outbox: world.outbox)

        let before = try await maintenance.maintain(feature: feature, cycleID: cycleID)
        guard case .posted(let beforeHash, _) = before else {
            Issue.record("expected posted, got \(before)")
            return
        }
        let beforeDescription = try #require(await world.board.issue(BoardObjectID(rawValue: "FEAT-1"))?.description)
        #expect(!beforeDescription.contains("[conflict:"))
        let beforeParts = try ManagedBlockFence.parts(of: beforeDescription).get()
        let beforeSentence = try #require(beforeParts.block.components(separatedBy: "\n").first)

        try journal.append(
            .mainlineConflictDetected(featureIssueID: "FEAT-1", repository: "frontend", paths: ["a.txt"]),
            act: .build, runID: world.runID, nightID: world.night.id
        )
        let after = try await maintenance.maintain(feature: feature, cycleID: cycleID)
        guard case .posted(let afterHash, _) = after else {
            Issue.record("expected posted, got \(after)")
            return
        }
        #expect(afterHash != beforeHash)
        let afterDescription = try #require(await world.board.issue(BoardObjectID(rawValue: "FEAT-1"))?.description)
        #expect(afterDescription.contains("[conflict: frontend]"))
        let afterParts = try ManagedBlockFence.parts(of: afterDescription).get()
        let afterSentence = try #require(afterParts.block.components(separatedBy: "\n").first)
        #expect(afterSentence.hasPrefix(beforeSentence))
    }

    @Test("The live set alone reposts: a Card cancelled drops the denominator, 2 of 3 to 2 of 2")
    func repostsOnLiveSetChange() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try makeRollUpWorld(journal)
        await world.board.seed(issue: "FEAT-1", description: ManagedBlockFence.initialDescription(rendered: ""))
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-1", branch: "yh-proj-feat", repositories: ["backend"]
        )
        let cycleID = try gateCycleID(journal, featureID: featureID)
        try insertRollUpCard(
            journal, cycleID: cycleID, .init(issueID: "BACK-1", repository: "backend", order: 1, state: .done)
        )
        try insertRollUpCard(
            journal, cycleID: cycleID, .init(issueID: "BACK-2", repository: "backend", order: 2, state: .done)
        )
        let toCancel = try insertRollUpCard(
            journal, cycleID: cycleID, .init(issueID: "BACK-3", repository: "backend", order: 3, state: .todo)
        )
        let feature = try #require(try journal.feature(issueID: "FEAT-1"))
        let maintenance = FeatureRollUpMaintenance(journal: journal, outbox: world.outbox)

        let before = try await maintenance.maintain(feature: feature, cycleID: cycleID)
        guard case .posted = before else {
            Issue.record("expected posted, got \(before)")
            return
        }
        let beforeDescription = try #require(await world.board.issue(BoardObjectID(rawValue: "FEAT-1"))?.description)
        #expect(beforeDescription.contains("2 of 3 Cards landed"))

        try setCardState(journal, cardID: toCancel, state: .cancelled)
        let after = try await maintenance.maintain(feature: feature, cycleID: cycleID)
        guard case .posted = after else {
            Issue.record("expected posted, got \(after)")
            return
        }
        let afterDescription = try #require(await world.board.issue(BoardObjectID(rawValue: "FEAT-1"))?.description)
        #expect(afterDescription.contains("2 of 2 Cards landed"))
    }

    @Test("A banked-answer marker appearing alone reposts")
    func repostsOnBankedAnswer() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try makeRollUpWorld(journal)
        await world.board.seed(issue: "FEAT-1", description: ManagedBlockFence.initialDescription(rendered: ""))
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-1", branch: "yh-proj-feat", repositories: ["backend"]
        )
        let cycleID = try gateCycleID(journal, featureID: featureID)
        let cardID = try insertRollUpCard(
            journal, cycleID: cycleID,
            .init(issueID: "BACK-1", repository: "backend", order: 1, state: .waitingOnYou, waitingReason: .question)
        )
        let feature = try #require(try journal.feature(issueID: "FEAT-1"))
        let maintenance = FeatureRollUpMaintenance(journal: journal, outbox: world.outbox)

        let before = try await maintenance.maintain(feature: feature, cycleID: cycleID)
        guard case .posted(let beforeHash, _) = before else {
            Issue.record("expected posted, got \(before)")
            return
        }
        let beforeDescription = try #require(await world.board.issue(BoardObjectID(rawValue: "FEAT-1"))?.description)
        #expect(!beforeDescription.contains("banked answer waiting"))

        try bankRollUpReply(journal, cardID: cardID, issueID: "BACK-1", nightID: world.night.id, runID: world.runID)
        let after = try await maintenance.maintain(feature: feature, cycleID: cycleID)
        guard case .posted(let afterHash, _) = after else {
            Issue.record("expected posted, got \(after)")
            return
        }
        #expect(afterHash != beforeHash)
        let afterDescription = try #require(await world.board.issue(BoardObjectID(rawValue: "FEAT-1"))?.description)
        #expect(afterDescription.contains("banked answer waiting"))
    }
}
