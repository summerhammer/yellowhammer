import Domain
import Foundation
import Testing

@testable import Engine
@testable import Journal
import Repositories

// OQ146/OQ147, R23: every outbound narrative passes one scrub, held-credential values by value. These
// assert what the board and the Publication stand-in RECEIVED. The scrub is a floor: nothing here claims
// that a secret Yellowhammer does not hold is caught.

private let scrubToken = "tok123abc"

private let scrubbing = NarrativeScrub(
    credentials: [scrubToken], homeDirectory: "/Users/alice", repositoryRoots: ["/Users/alice/dev/app"]
)

/// Quoted Check output: a held token, a home path under a declared repository, a home path outside any,
/// and an environment dump line.
private let quotedCheck = """
    request failed with Bearer \(scrubToken)
    /Users/alice/dev/app/Sources/A.swift:12: error
    see /Users/alice/notes/x for more
    GITHUB_TOKEN=some-other-value
    """

private let scrubbedCheck = """
    request failed with Bearer <redacted>
    Sources/A.swift:12: error
    see ~/notes/x for more
    GITHUB_TOKEN=<redacted>
    """

@Suite("Narrative scrub wiring (OQ146/OQ147, R23)")
struct NarrativeScrubWiringTests {
    @Test("A Work Card comment reaches the board scrubbed")
    func workCardComment() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let issue = await board.seed(issue: "issue-1", description: nil)
        let outbox = try outbox(journal, board: board, scrub: { scrubbing })

        _ = try await outbox.post(OutboxWrite(
            key: "comment:issue-1:check", write: .createComment(issue: issue, body: quotedCheck)
        ))

        let comments = await board.comments
        #expect(comments.map(\.body) == [scrubbedCheck])
    }

    @Test("A Managed Block rewrite and a Managed Block line reach the board scrubbed")
    func managedBlockWrites() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let issue = await board.seed(issue: "issue-1", description: fencedDescription)
        let outbox = try outbox(journal, board: board, scrub: { scrubbing })

        _ = try await outbox.post(OutboxWrite(
            key: "block:issue-1", write: .rewriteManagedBlock(issue: issue, rendered: quotedCheck)
        ))
        var description = try #require(await board.issue(issue)?.description)
        #expect(description.contains(scrubbedCheck))
        #expect(!description.contains(scrubToken))
        #expect(!description.contains("/Users/alice"))

        let prefix = "Check: "
        _ = try await outbox.post(OutboxWrite(
            key: "line:issue-1",
            write: .updateManagedBlockLine(
                issue: issue, prefix: prefix,
                line: prefix + "failed at /Users/alice/dev/app/Sources/A.swift:12 with \(scrubToken)"
            )
        ))
        description = try #require(await board.issue(issue)?.description)
        #expect(description.contains("Check: failed at Sources/A.swift:12 with <redacted>"))
        #expect(!description.contains(scrubToken))
    }

    @Test("A Night Summary posted to the Night Card through the invocation's Outbox is scrubbed")
    func nightSummaryOnNightCard() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let writing = boards.writing
        let board = ActBoard(reading: FakeReadingBoard([]), writing: writing, provisioning: boards.provisioning)

        let invocation = EngineInvocation(
            act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board,
            narrativeScrub: { scrubbing },
            work: { context in
                let outbox = try #require(context.outbox)
                let issue = BoardObjectID(rawValue: try #require(context.night.nightCardIssueID))
                _ = try await outbox.post(OutboxWrite(
                    key: "night-summary:test", write: .rewriteManagedBlock(issue: issue, rendered: quotedCheck)
                ))
            }
        )
        try await invocation.run()

        let issue = try #require(await writing.liveIssues.first)
        let description = try #require(issue.description)
        #expect(description.contains(scrubbedCheck))
        #expect(!description.contains(scrubToken))
    }

    @Test("A created issue's title and description reach the board scrubbed")
    func createIssueText() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let outbox = try outbox(journal, board: board, scrub: { scrubbing })

        _ = try await outbox.post(OutboxWrite(
            key: "card:create",
            write: card("Fix \(scrubToken) in /Users/alice/dev/app/B.swift", description: quotedCheck)
        ))

        let created = try #require(await board.liveIssues.first)
        #expect(created.title == "Fix <redacted> in B.swift")
        #expect(created.description == scrubbedCheck)
    }

    @Test("The Journal's payload for an accepted entry is already scrubbed")
    func journalPayloadIsScrubbed() throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let outbox = try outbox(journal, board: FakeWritingBoard(), scrub: { scrubbing })

        let entry = try outbox.accept(OutboxWrite(
            key: "comment:issue-1:check",
            write: .createComment(issue: BoardObjectID(rawValue: "issue-1"), body: quotedCheck)
        ))

        #expect(!entry.payload.contains(scrubToken))
        #expect(!entry.payload.contains("/Users/alice"))
        #expect(entry.payload.contains("<redacted>"))
        #expect(entry.payload.contains("A.swift:12: error"))
        #expect(!entry.payload.contains("dev"))
    }

    @Test("A pull request's title and body reach the Publication scrubbed")
    func pullRequestTitleAndBody() async throws {
        let local = TestGitRepo(name: "pr-scrub-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "yh-proj-feat"])
        await local.addRemote(url: "git@github.com:summerhammer/backend.git")

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        // No board object for the Feature, so its title is its issue id, which here carries the token.
        let featureID = try insertReconcilerFeature(env.journal, issueID: "FEAT-\(scrubToken)")
        try env.journal.recordWorktreeName(
            featureID: featureID, worktreeName: WorktreeName(rawValue: landBranch.rawValue)
        )
        let cycleID = try insertReconcilerCycle(env.journal, featureID: featureID)
        try insertReconcilerCard(
            env.journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .done,
            title: "Fix /Users/alice/dev/app/Sources/A.swift:12 using \(scrubToken)"
        )
        let (feature, _) = try #require(try env.journal.inFlightFeature())

        let stub = StubPublicationAdapter(
            result: .success(.opened(url: "https://github.com/summerhammer/backend/pull/1"))
        )
        let seam = FeatureBranchPullRequest(publication: stub, clock: { landEpoch }, scrub: { scrubbing })
        let laneContext = LandActLaneContext(
            act: env.context, feature: feature, cycleID: cycleID,
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID))
        )
        let outcome = try await seam.open(
            laneContext, push: LanePushOutcome(pushed: true, commit: "deadbeef"), mergeOutcome: nil
        )
        #expect(outcome.opened)

        let draft = try #require(await stub.calls.first)
        #expect(draft.title.contains("FEAT-<redacted>"))
        #expect(!draft.title.contains(scrubToken))
        #expect(draft.body.contains("Fix Sources/A.swift:12 using <redacted>"))
        #expect(!draft.body.contains(scrubToken))
        #expect(!draft.body.contains("/Users/alice"))
    }
}
