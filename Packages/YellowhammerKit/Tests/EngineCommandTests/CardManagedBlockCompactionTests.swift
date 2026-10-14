import Domain
import Foundation
import Testing

@testable import Engine
@testable import Journal

// board-projection/maintain-the-managed-block, "budget on rewrite": a Work Card's Attempts section compacts
// in a fixed order — older Attempts to one line each, oldest first; every account but the latest into one
// "N earlier Attempts" line; the latest Attempt last — and the parser reads every rendering alike.

@Suite("Work Card Managed Block: compaction ladder")
struct CardManagedBlockCompactionTests {
    private let route = Route(cli: "claude", model: "opus", effort: "high")!

    private func account(ordinal: Int, rounds: Int = 2, outcome: String = "rounds-exhausted") -> AttemptAccount {
        let records = (0..<rounds).map {
            RoundRecord(
                id: Int64($0), attemptID: Int64(ordinal), lens: .check, verdict: "failed",
                requestedChanges: String(repeating: "Please fix the failing test. ", count: 15),
                judgedCommit: "abc123\($0)", createdAt: Date()
            )
        }
        let record = AttemptRecord(
            id: Int64(ordinal), cardID: 1, budgetEpoch: 0, route: route, classification: nil, result: outcome,
            consumedHow: nil, checkDeclaredNone: false, routeSource: nil, overridePin: nil, startedAt: Date(),
            endedAt: Date(), rounds: records, preservedRef: nil, preservedCommit: nil
        )
        let run = CheckRunRecord(
            eventID: Int64(ordinal), attemptID: Int64(ordinal), result: .failed, exitStatus: 1, output: nil,
            judgedCommit: "abc1234", occurredAt: Date()
        )
        return AttemptAccount(ordinal: ordinal, record: record, checkRuns: [run])
    }

    private func block(attempts: Int) -> CardManagedBlock {
        CardManagedBlock(
            kind: "impl.boilerplate", repository: "backend", scope: ["Sources/A.swift"], state: .blocked,
            lanePosition: 1, laneLength: 2,
            brief: ArchitecturalBrief(prose: "Add the endpoint.\n\nKeep the handler small.", transcriptions: []),
            definitionOfDone: [
                DoDClause(cid: "C1", text: "The endpoint answers 200", citation: "api/get", citationProvenance: "")
            ],
            attempts: (1...max(attempts, 1)).prefix(attempts).map { account(ordinal: $0) }
        )
    }

    /// The Attempts section's lines, up to the footer.
    private func attemptsSection(_ rendering: String) -> [String] {
        let lines = rendering.components(separatedBy: "\n")
        let start = lines.firstIndex(of: "### Attempts") ?? 0
        let end = lines.firstIndex(of: CardManagedBlock.footer) ?? lines.count
        return Array(lines[start..<end])
    }

    @Test("The first rung is the full rendering and each rung is shorter than the last")
    func ladderShrinks() {
        let block = block(attempts: 4)
        let renderings = block.renderings()
        #expect(renderings.first == block.render())
        #expect(renderings.count == 6)
        let lengths = renderings.map(\.utf16.count)
        #expect(lengths == lengths.sorted(by: >))
        #expect(Set(lengths).count == lengths.count)
    }

    @Test("Older Attempts lose their detail oldest first, each keeping a one-line account")
    func olderAttemptsGoFirst() {
        let renderings = block(attempts: 3).renderings()
        let firstRung = attemptsSection(renderings[1])
        let oneLine = "- Attempt 1 — `claude/opus/high` · Check: failed on `abc1234` · Rounds: 2 · "
            + "Outcome: rounds-exhausted"
        #expect(firstRung.contains(oneLine))
        #expect(firstRung.contains("#### Attempt 2 — `claude/opus/high`"))
        #expect(firstRung.contains("#### Attempt 3 — `claude/opus/high`"))
        let secondRung = attemptsSection(renderings[2])
        #expect(secondRung.filter { $0.hasPrefix("- Attempt ") }.count == 2)
        #expect(secondRung.contains("#### Attempt 3 — `claude/opus/high`"))
    }

    @Test("Then every account but the latest collapses into one counted line, and last the latest is one line")
    func collapseThenLatest() throws {
        let renderings = block(attempts: 4).renderings()
        let collapsed = attemptsSection(renderings[4])
        #expect(collapsed.contains("- 3 earlier Attempts — see the Journal"))
        #expect(collapsed.contains("#### Attempt 4 — `claude/opus/high`"))
        let last = attemptsSection(try #require(renderings.last))
        let accountLines = last.filter { $0.hasPrefix("- ") }
        #expect(accountLines.count == 2)
        #expect(accountLines[0] == "- 3 earlier Attempts — see the Journal")
        #expect(accountLines[1].hasPrefix("- Attempt 4 — `claude/opus/high` · Check: "))
        #expect(!last.contains { $0.contains("requested changes") })
    }

    @Test("A single Attempt has only itself to compact; none has no ladder at all")
    func smallLadders() {
        #expect(block(attempts: 1).renderings().count == 2)
        #expect(block(attempts: 0).renderings().count == 1)
    }

    @Test("On machine text alone the compacted block fits a budget the full one overshoots")
    func fitsOnMachineTextAlone() throws {
        let block = block(attempts: 5)
        let renderings = block.renderings()
        let last = try #require(renderings.last)
        let limit = BoardDescriptionLimit(maximum: 100_000, unit: .utf16CodeUnits)
        let target = ManagedBlockFence.initialDescription(rendered: last).utf16.count
        let budget = try DescriptionBudget(configured: target, limit: limit)
        let chosen = try #require(renderings.first { budget.fits(ManagedBlockFence.initialDescription(rendered: $0)) })
        #expect(chosen == last)
        #expect(!budget.fits(ManagedBlockFence.initialDescription(rendered: block.render())))
    }

    @Test("Every rendering reads back the same: prose, Definition of Done clauses and Scope line survive")
    func parserRoundTrip() {
        let block = block(attempts: 4)
        let expected = CardManagedBlockParser.parse(block: block.render())
        #expect(expected.briefProse == "Add the endpoint.\n\nKeep the handler small.")
        #expect(expected.clauses.map(\.cid) == ["C1"])
        #expect(expected.scope == ["Sources/A.swift"])
        for rendering in block.renderings() {
            #expect(CardManagedBlockParser.parse(block: rendering) == expected)
        }
    }

    @Test("The widest compacted section reserves at least what any real compacted section takes")
    func reserveCoversRealSections() throws {
        let reserve = CardManagedBlock.widestCompactedAttemptsSection(longestRoute: route)
        let real = try #require(block(attempts: 4).renderings().last)
        #expect(reserve.utf16.count >= attemptsSection(real).joined(separator: "\n").utf16.count)
        #expect(reserve.contains("see the Journal"))
        #expect(reserve.hasPrefix("\n### Attempts"))
    }
}
