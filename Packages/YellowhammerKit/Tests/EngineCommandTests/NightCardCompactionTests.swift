import Domain
import Foundation
import Testing

@testable import Engine
@testable import Journal

// board-projection/write-the-night-summary, "night-card-budget": a Night Card compacts in a fixed order —
// the Cards' detail, then the Standing entries, then the Exception lines — stopping as soon as it fits. The
// `**Verdict:**` line never compacts and every collapse states its count.

@Suite("Night Card: compaction ladder")
struct NightCardCompactionTests {
    private let night = NightRecord(
        id: 1, projectID: ProjectID(rawValue: "fixture")!, nightStart: nightCardNightStart,
        mode: .real, state: .closed, nightCardIssueID: "NIGHT-1", openedAt: deltaEpoch,
        completedAt: deltaEpoch, closeReason: .nightEnd, verdict: nil, triagedAt: nil
    )
    private let verdict = "2 decisions waiting · advanced · closed"

    private func lines(_ prefix: String, _ count: Int) -> [String] {
        (1...max(count, 1)).prefix(count).map { "\(prefix) \($0) \(String(repeating: "detail ", count: 6))" }
    }

    private func render(_ compaction: NightCardCompaction) -> String {
        NightCardBlock.completed(
            night: night, projectID: night.projectID, verdictLine: verdict,
            cardLines: lines("Card", 12), exceptions: lines("Exception", 12),
            standingItems: lines("Standing item", 10), unadoptedCards: lines("Unadopted", 6),
            inFlightFeature: lines("Feature", 1),
            cardShortLines: (1...12).map { "Card \($0) short" }, compaction: compaction
        )
    }

    @Test("The default compaction renders exactly what completed always rendered")
    func defaultIsUnchanged() {
        let plain = NightCardBlock.completed(
            night: night, projectID: night.projectID, verdictLine: verdict,
            cardLines: lines("Card", 12), exceptions: lines("Exception", 12),
            standingItems: lines("Standing item", 10), unadoptedCards: lines("Unadopted", 6),
            inFlightFeature: lines("Feature", 1)
        )
        #expect(render(NightCardCompaction()) == plain)
    }

    @Test("The ladder is bounded and ordered: Cards, then Standing, then Exceptions, each down to none kept")
    func ladderOrder() {
        let ladder = NightCardCompaction.ladder(cards: 12, standing: 10, exceptions: 12)
        #expect(ladder.first == NightCardCompaction())
        #expect(ladder.count == 1 + 4 + 4 + 4)
        #expect(ladder.map(\.detailedCards) == [nil, 8, 4, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(ladder.map(\.standingKept) == [nil, nil, nil, nil, nil, 8, 4, 2, 0, 0, 0, 0, 0])
        #expect(ladder.map(\.exceptionsKept) == [nil, nil, nil, nil, nil, nil, nil, nil, nil, 8, 4, 2, 0])
    }

    @Test("A Night with nothing over any threshold has the one rung; empty stages are skipped")
    func smallNight() {
        #expect(NightCardCompaction.ladder(cards: 0, standing: 0, exceptions: 0) == [NightCardCompaction()])
        let ladder = NightCardCompaction.ladder(cards: 0, standing: 0, exceptions: 3)
        #expect(ladder.map(\.exceptionsKept) == [nil, 2, 0])
    }

    @Test("Cards' oldest detail becomes short lines first, keeping the most recent in detail")
    func cardsShortenFromTheTop() {
        let block = render(NightCardCompaction(detailedCards: 2))
        #expect(block.contains("- Card 1 short"))
        #expect(block.contains("- Card 10 short"))
        #expect(!block.contains("- Card 10 detail"))
        #expect(block.contains("- Card 11 detail"))
        #expect(block.contains("- Card 12 detail"))
    }

    @Test("Standing entries collapse into a counted line; exceptions keep the most recent")
    func standingAndExceptionsCollapse() {
        let block = render(NightCardCompaction(detailedCards: 0, standingKept: 4, exceptionsKept: 2))
        #expect(block.contains("- and 6 more — see the app"))  // Standing items: 10 − 4
        #expect(block.contains("- and 2 more — see the app"))  // un-adopted: 6 − 4
        #expect(block.contains("- and 10 more — see the app"))  // exceptions: 12 − 2
        #expect(block.contains("- Exception 12 "))
        #expect(!block.contains("- Exception 10 "))
        let none = render(NightCardCompaction(detailedCards: 0, standingKept: 0, exceptionsKept: 0))
        #expect(none.contains("- 10 entries — see the app"))
        #expect(none.contains("- 1 entry — see the app"))
    }

    @Test("The most compacted Night Card fits a budget far below the full one, with its Verdict line intact")
    func fitsAndKeepsTheVerdict() throws {
        let ladder = NightCardCompaction.ladder(cards: 12, standing: 10, exceptions: 12)
        let renderings = ladder.map(render)
        #expect(renderings.allSatisfy { $0.contains("**Verdict:** \(verdict)") })
        let lengths = renderings.map(\.utf16.count)
        #expect(lengths == lengths.sorted(by: >))
        let limit = BoardDescriptionLimit(maximum: 100_000, unit: .utf16CodeUnits)
        let target = ManagedBlockFence.initialDescription(rendered: try #require(renderings.last)).utf16.count
        let budget = try DescriptionBudget(configured: target, limit: limit)
        let chosen = try #require(renderings.first { budget.fits(ManagedBlockFence.initialDescription(rendered: $0)) })
        #expect(chosen == renderings.last)
        #expect(chosen.contains("**Verdict:**"))
    }

    @Test("A completed Night Card with many Exception lines is written compacted, within the budget, Verdict intact")
    func completionWritesTheCompactedRung() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let writing = boards.writing
        let limit = BoardDescriptionLimit(maximum: 100_000, unit: .utf16CodeUnits)
        let budget = try DescriptionBudget(configured: 2_500, limit: limit)
        let board = ActBoard(
            reading: FakeReadingBoard([]), writing: writing, provisioning: boards.provisioning,
            descriptionBudget: budget
        )
        try await EngineInvocation(
            act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board, work: { _ in }
        ).run()
        let openNight = try #require(try journal.currentNight())
        let noise = RunID()
        for index in 1...40 {
            try journal.append(
                .mainlineFetchFailed(repository: "repo-\(index)", reason: "the remote did not answer in time"),
                act: .author, runID: noise, nightID: openNight.id
            )
        }

        try await EngineInvocation(
            act: .land, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), closesNight: true, board: board, work: { _ in }
        ).run()

        let issue = try #require(await writing.liveIssues.first)
        let description = try #require(issue.description)
        #expect(budget.fits(description))
        #expect(description.contains("**Verdict:**"))
        #expect(description.contains("**Exceptions:**"))
        #expect(description.contains("and 32 more — see the app"))
        #expect(description.contains("`repo-40`"))
        #expect(!description.contains("`repo-1`"))
        #expect(try journal.events(ofType: .managedBlockOverBudget).isEmpty)
    }
}
