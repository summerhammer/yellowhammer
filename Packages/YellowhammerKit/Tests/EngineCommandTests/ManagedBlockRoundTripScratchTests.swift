import Config
import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Security
import Testing

/// Against the real scratch Linear workspace — the done-condition a stub cannot prove (issue #433): Linear
/// parses a description's Markdown and re-serialises it, and a Managed Block read back must still render
/// the same as the one written. Opt-in only:
///
///     YH_LINEAR_SCRATCH_TESTS=1 YH_LINEAR_INSTALLATION=<local name> YH_LINEAR_PROJECT_ID=… \
///         swift test --package-path Packages/YellowhammerKit --filter ManagedBlockRoundTripScratchTests
///
/// Uses the token pair of the Board Connection named `YH_LINEAR_INSTALLATION`, already stored in the Keychain
/// item `linear-<name>` (P17.3/P17.4), via `BoardBinding` — no client id or secret of its own.
@Suite(
    "Managed Block round trip through Linear (live)",
    .enabled(if: ProcessInfo.processInfo.environment["YH_LINEAR_SCRATCH_TESTS"] == "1")
)
struct ManagedBlockRoundTripScratchTests {
    /// Every Markdown shape Linear was seen to rewrite: a bracket, a domain-like token, double-backtick
    /// code and an indented code block.
    private static let transcriptionContent = """
    Stored [bracket] and night.id here, with ``double-backtick`` code.

        let x = 1
        let y = 2

    - first
    - second
    """

    private static let clauseText = "Offsets are exactly [22:19, 22:34] and fixture.open() works"

    @Test("A fenced Managed Block read back from Linear renders the same, though not byte-identical")
    func managedBlockRendersTheSameAfterLinearRewritesIt() async throws {
        guard let board = try Self.liveBoard() else {
            return
        }

        let scope = try await board.provisioning.linearProject()
        let team = try #require(scope.teams.first)
        let written = Self.fencedDescription()
        let draft = BoardIssueDraft(
            team: team.id, title: "yh managed-block round trip \(UUID())", description: written
        )
        guard case .created(let issueID) = try await board.writing.createIssue(draft, clientID: UUID()) else {
            Issue.record("expected the scratch issue create to be .created")
            return
        }

        do {
            try await Self.verifyRoundTrip(board: board, issueID: issueID, written: written)
        } catch {
            try? await board.writing.archiveIssue(issueID)
            throw error
        }
        try await board.writing.archiveIssue(issueID)
    }

    private static func fencedDescription() -> String {
        let block = TranscriptionBlock(
            repository: "backend", paths: ["Sources/a.swift"], mainlineCommit: "deadbeef",
            content: transcriptionContent, contentHash: ManagedBlockFence.sha256(transcriptionContent),
            authorSupplied: false
        )
        let clause = DoDClause(
            cid: "c1", text: clauseText, citation: "resolvable/story", citationProvenance: "Author-supplied"
        )
        let rendered = CardManagedBlock(
            kind: "card", repository: "backend", state: .todo, lanePosition: 1, laneLength: 1,
            brief: ArchitecturalBrief(prose: "A brief.", transcriptions: [block]),
            definitionOfDone: [clause], attempts: []
        ).render()
        return ManagedBlockFence.initialDescription(rendered: rendered)
    }

    private static func verifyRoundTrip(board: ActBoard, issueID: BoardObjectID, written: String) async throws {
        let snapshot = try await board.writing.issueDescription(issueID)
        let readBack = try #require(snapshot.description)

        if readBack == written {
            print("ManagedBlockRoundTripScratchTests note: Linear returned the description byte-identical; "
                + "the rewrite this test exists to cover did not happen")
        } else {
            print("ManagedBlockRoundTripScratchTests: Linear rewrote the description, as expected")
        }

        guard case .success(let parts) = ManagedBlockFence.parts(of: readBack) else {
            Issue.record("the read-back description lost its Managed Block delimiters")
            return
        }
        let parsed = CardManagedBlockParser.parse(block: parts.block)
        #expect(parsed.transcriptions.count == 1)
        #expect(parsed.clauses.count == 1)
        // The Card carries the block's reference only, so the stamp is what must survive Linear's rewrite.
        for transcription in parsed.transcriptions {
            #expect(transcription.repository == "backend", "the stamp read back as: \(transcription)")
            #expect(transcription.paths == ["Sources/a.swift"], "the stamp read back as: \(transcription)")
            #expect(transcription.commitField == "deadbeef", "the stamp read back as: \(transcription)")
        }
        for clause in parsed.clauses {
            #expect(
                MarkdownEquivalence.rendersSame(clause.text, clauseText),
                "the clause read back as: \(clause.text)"
            )
        }
    }

    /// The live scratch Board Port, from the same environment variables and Keychain item as
    /// `NightCardScratchTests`; nil (printing why) when the scratch environment is not set up.
    private static func liveBoard() throws -> ActBoard? {
        let environment = ProcessInfo.processInfo.environment
        guard let linearProjectID = environment["YH_LINEAR_PROJECT_ID"], !linearProjectID.isEmpty else {
            print("ManagedBlockRoundTripScratchTests skipped: YH_LINEAR_PROJECT_ID is not set")
            return nil
        }
        guard let installation = environment["YH_LINEAR_INSTALLATION"], !installation.isEmpty else {
            print("ManagedBlockRoundTripScratchTests skipped: YH_LINEAR_INSTALLATION is not set")
            return nil
        }
        guard keychainSecret(account: "linear-\(installation)") != nil else {
            print("ManagedBlockRoundTripScratchTests skipped: no Keychain item for service dev.yellowhammer, "
                + "account linear-\(installation)")
            return nil
        }

        let machine = try MachineConfiguration.parse("""
            [board.linear.connections."\(installation)"]
            credential = "keychain:linear-\(installation)"
            workspace = "workspace-1"
            yellowhammer_identity = "app-user-1"

            [code_hosting.github.connections.github]
            type = "keychain"
            credential = "keychain:github"
            """, file: "config.toml")

        let project = try ProjectConfiguration.parse("""
            id = "yellowhammer"
            name = "Yellowhammer"
            board = { linear = { connection = "\(installation)", project = "\(linearProjectID)" } }
            code_hosting = { connection = "github" }
            spec_source = "~/Developer/yellowhammer-spec"

            [[repos]]
            name = "backend"
            path = "~/Developer/yellowhammer-backend"
            role = "backend"
            check = "swift test"
            """, file: "yellowhammer.toml")

        return try BoardBinding.actBoard(machine: machine, project: project)
    }

    private static func keychainSecret(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.yellowhammer",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
