import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// roadmap P9.6 (spec: feature-authoring/author-an-architectural-brief): every Card's Architectural
// Brief and its Transcription Blocks are authored inside the Managed Block fence, transcribed against
// the merged mainline before anything is accepted into the Outbox, and a contract the author Act cannot
// read halts the whole Feature. These assert format and provenance only — never what a brief says.

/// A throwaway git repository, shared by every file in this test target (``Repositories/GitRunner`` is
/// public, and `Tests/RepositoriesTests/GitFixture.swift` lives in a separate test target this one
/// cannot import).
struct EngineGitFixture: ~Copyable {
    let url: URL
    private let git = GitRunner()

    init(name: String = UUID().uuidString) {
        url = FileManager.default.temporaryDirectory.appending(
            component: "yh-authoring-git-\(name)", directoryHint: .isDirectory
        )
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
    func commit(filename: String, content: String, message: String = "commit") async throws -> String {
        let fileURL = url.appendingPathComponent(filename)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        _ = await git.run(["-C", path, "add", "."])
        _ = await git.run(["-C", path, "commit", "-m", message])
        let result = await git.run(["-C", path, "rev-parse", "--verify", "HEAD"])
        return try #require(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : result.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

@Suite("Authoring transaction: Architectural Briefs and Transcription Blocks (P9.6)")
struct AuthoringTranscriptionTests {
    @Test("""
        Authored Card description carries the brief before the Definition of Done, both inside the \
        fence, and the Transcription Block's start marker carries repo, every path, symbol and the \
        mainline commit from context.mainlines, with hash == sha256(content)
        """)
    func briefAndTranscriptionBlockAreRenderedInFence() async throws {
        let kind = try authoringKind()
        let breakdown = FeatureBreakdown(
            definitionOfDone: [authoringClause("The Feature is done.")],
            cards: [
                CardDraft(
                    repository: "backend", kind: kind, title: "Backend one", unitOfWork: "Do it",
                    brief: "Approach for Backend one.",
                    definitionOfDone: [authoringClause("Backend one is done.")],
                    contracts: [ContractDraft(repository: "mobile", paths: ["a.swift", "b.swift"], symbol: "Foo")]
                )
            ]
        )
        let rig = try await AuthoringRig(drafting: ScriptedBreakdown(breakdown))
        let outcome = try await rig.run(rig.context())

        #expect(outcome == .authored)
        let live = await rig.boards.writing.liveIssues
        let backendOne = try #require(live.first { $0.title == "Backend one" })
        let description = try #require(backendOne.description)

        guard case .success(let parts) = ManagedBlockFence.parts(of: description) else {
            Issue.record("Card description is not fenced")
            return
        }
        let briefRange = try #require(parts.block.range(of: "### Architectural Brief"))
        let dodRange = try #require(parts.block.range(of: "### Definition of Done"))
        #expect(briefRange.lowerBound < dodRange.lowerBound)
        #expect(parts.block.contains("Approach for Backend one."))

        let expectedContent = "Transcribed a.swift,b.swift from mobile."
        let expectedHash = MainlineReader.sha256(expectedContent)
        let expectedCommit = try #require(selectionMainlines()["mobile"]?.commit)
        let expectedMarker = "<!-- yh:transcription:start repo=mobile paths=a.swift,b.swift " +
            "symbol=Foo commit=\(expectedCommit) hash=\(expectedHash) -->"
        #expect(parts.block.contains(expectedMarker))
        #expect(parts.block.contains(expectedContent))
        #expect(parts.block.contains("<!-- yh:transcription:end -->"))
    }

    @Test("""
        The authored description round-trips through the parser: a Transcription Block's parsed \
        contentHash equals its recordedHash, including content with a trailing newline and multiple \
        paths, and clause cids parse back unchanged
        """)
    func roundTripsThroughParser() async throws {
        struct TrailingNewlineTranscriber: ContractTranscribing {
            func transcribe(
                _ contract: ContractDraft, in projectRepositories: ProjectRepositories, mainlines: ResolvedMainlines
            ) async throws -> TranscriptionBlock {
                let content = "line one\nline two\n"
                return TranscriptionBlock(
                    repository: contract.repository, paths: contract.paths, symbol: contract.symbol,
                    mainlineCommit: "deadbeef", content: content, contentHash: MainlineReader.sha256(content),
                    authorSupplied: false
                )
            }
        }

        let kind = try authoringKind()
        let breakdown = FeatureBreakdown(
            definitionOfDone: [authoringClause("The Feature is done.")],
            cards: [
                CardDraft(
                    repository: "backend", kind: kind, title: "Backend one", unitOfWork: "Do it",
                    brief: "Approach for Backend one.",
                    definitionOfDone: [authoringClause("Backend one is done.")],
                    contracts: [ContractDraft(repository: "mobile", paths: ["x.swift", "y.swift"])]
                )
            ]
        )
        let rig = try await AuthoringRig(
            drafting: ScriptedBreakdown(breakdown), transcribing: TrailingNewlineTranscriber()
        )
        let outcome = try await rig.run(rig.context())
        #expect(outcome == .authored)

        let live = await rig.boards.writing.liveIssues
        let backendOne = try #require(live.first { $0.title == "Backend one" })
        let description = try #require(backendOne.description)
        guard case .success(let parts) = ManagedBlockFence.parts(of: description) else {
            Issue.record("Card description is not fenced")
            return
        }
        let parsed = CardManagedBlockParser.parse(block: parts.block)

        #expect(parsed.transcriptions.count == 1)
        let transcription = try #require(parsed.transcriptions.first)
        #expect(transcription.paths == ["x.swift", "y.swift"])
        #expect(transcription.content == "line one\nline two\n")
        #expect(transcription.contentHash == transcription.recordedHash)

        #expect(parsed.clauses.count == 1)
        #expect(parsed.clauses.first?.cid == "c1")
    }

    @Test("""
        Journal rows after authoring: one architectural_brief row per new Card, Transcription Block \
        rows carry full provenance with author_supplied == false, and a Card with no contracts has a \
        brief and zero blocks; the brief is no longer missing from the Journal's own accessors
        """)
    func journalRowsAfterAuthoring() async throws {
        let kind = try authoringKind()
        let breakdown = FeatureBreakdown(
            definitionOfDone: [authoringClause("The Feature is done.")],
            cards: [
                CardDraft(
                    repository: "backend", kind: kind, title: "Backend one", unitOfWork: "Do it",
                    brief: "Approach for Backend one.",
                    definitionOfDone: [authoringClause("Backend one is done.")],
                    contracts: [ContractDraft(repository: "mobile", paths: ["a.swift"], symbol: "Foo")]
                ),
                CardDraft(
                    repository: "mobile", kind: kind, title: "Mobile one", unitOfWork: "Do it",
                    brief: "Approach for Mobile one.",
                    definitionOfDone: [authoringClause("Mobile one is done.")]
                )
            ]
        )
        let rig = try await AuthoringRig(drafting: ScriptedBreakdown(breakdown))
        let outcome = try await rig.run(rig.context())
        #expect(outcome == .authored)

        let live = await rig.boards.writing.liveIssues
        let backendOne = try #require(live.first { $0.title == "Backend one" })
        let mobileOne = try #require(live.first { $0.title == "Mobile one" })
        let backendRow = try #require(try rig.journal.card(issueID: backendOne.id.rawValue))
        let mobileRow = try #require(try rig.journal.card(issueID: mobileOne.id.rawValue))

        #expect(try rig.journal.architecturalBriefProse(cardID: backendRow.id) == "Approach for Backend one.")
        #expect(try rig.journal.architecturalBriefProse(cardID: mobileRow.id) == "Approach for Mobile one.")

        let backendBlocks = try rig.journal.transcriptionBlocks(cardID: backendRow.id)
        #expect(backendBlocks.count == 1)
        let block = try #require(backendBlocks.first)
        #expect(block.repository == "mobile")
        #expect(block.paths == ["a.swift"])
        #expect(block.symbol == "Foo")
        #expect(block.mainlineCommit != nil)
        #expect(block.authorSupplied == false)

        // A Card with no contracts has a brief and zero blocks.
        #expect(try rig.journal.transcriptionBlocks(cardID: mobileRow.id).isEmpty)
    }
}
