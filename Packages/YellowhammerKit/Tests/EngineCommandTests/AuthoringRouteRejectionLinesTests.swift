import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// The Night Card words one line per cause for the Routes an authoring walk rejected, before the fault line
// the walk ended in (spec: morning-report/disclose-a-failure#each-route).

private func overrun(_ size: Int) -> String {
    "Work Card \"Serve\" (backend) composes \(size) UTF-16 code units, over the description budget of 10,000: A 1"
}

@Suite("Night Card: one line per rejected authoring Route")
struct AuthoringRouteRejectionLinesTests {
    private func lines(_ events: [JournalEvent], runs: [RunID]? = nil) async throws -> [String] {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let run = RunID()
        _ = try journal.claimActLease(act: .author, runID: run, mode: .rehearsal)
        let night = try journal.openNight(nightStart: nightCardNightStart, mode: .rehearsal, act: .author, runID: run)
            .night
        let outbox = Outbox(journal: journal, board: boards.writing, runID: run, act: .author, nightID: night.id)
        let maintenance = NightCardMaintenance(journal: journal, outbox: outbox, provisioning: boards.provisioning)
        for (index, event) in events.enumerated() {
            try journal.append(event, act: .author, runID: runs?[index] ?? run, nightID: night.id)
        }
        return try maintenance.authoringLines(night: night)
    }

    private func rejected(
        _ route: String, _ ordinal: Int, _ cause: AuthoringRouteRejectionCause, _ reason: String
    ) -> JournalEvent {
        .authoringRouteRejected(pass: .breakdown, route: route, ordinal: ordinal, cause: cause, reason: reason)
    }

    @Test("Routes sharing a cause fold into one line before the fault line, keeping each Route's numbers")
    func sameCauseFolds() async throws {
        let result = try await lines([
            rejected("claude/fable/high", 1, .overDescriptionBudget, overrun(12_153)),
            rejected("codex/gpt-6.1-sol/high", 2, .overDescriptionBudget, overrun(11_987)),
            .featureBreakdownRejected(name: "Feature", reason: "no Route left")
        ])
        #expect(result.count == 2)
        #expect(result[0] == "`claude/fable/high`, `codex/gpt-6.1-sol/high`: over the description budget — "
            + "12,153 and 11,987 of 10,000")
        #expect(result[1].contains("Authoring Feature `Feature` failed"))
    }

    @Test("Different causes are separate lines in walk order, each with the Route's one-line reason")
    func differentCauses() async throws {
        let result = try await lines([
            rejected("claude/fable/high", 1, .overDescriptionBudget, overrun(12_153)),
            rejected("codex/gpt-6.1-sol/high", 2, .exited, "breakdown on codex/gpt-6.1-sol/high exited with status 2"),
            .featureSelectionFailed(reason: "no Route left")
        ])
        #expect(result.count == 3)
        #expect(result[0] == "`claude/fable/high`: over the description budget — "
            + "Work Card \"Serve\" (backend) is 12,153 of 10,000 description budget")
        #expect(result[1] == "`codex/gpt-6.1-sol/high`: exited — breakdown on codex/gpt-6.1-sol/high exited "
            + "with status 2")
        #expect(result[2].contains("Selecting a Feature failed"))
    }

    @Test("Rejections of a walk that ended in no fault add no lines")
    func noFaultNoLines() async throws {
        let result = try await lines([rejected("claude/fable/high", 1, .unavailable, "no executable")])
        #expect(result.isEmpty)
    }

    @Test("A rejection is not itself an authoring line or a problem")
    func rejectionIsNeitherLineNorProblem() {
        let event = rejected("claude/fable/high", 1, .unavailable, "no executable")
        #expect(NightCardMaintenance.authoringLine(for: event) == nil)
    }
}
