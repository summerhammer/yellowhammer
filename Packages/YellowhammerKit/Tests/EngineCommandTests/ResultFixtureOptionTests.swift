import Domain
@testable import EngineCommand
import Engine
import Testing

// P15.2: `--result-fixture <pass>=<fixture>`, shared by `yh rehearse` and the three Act commands.

@Suite("ResultFixtureOption parsing")
struct ResultFixtureOptionTests {
    @Test("Valid pairs produce the pass-to-fixture map, fixture name with or without .json")
    func validPairsProduceMap() throws {
        let map = try ResultFixtureOption.parse(["worker=worker-question", "reviewer=reviewer-approved.json"])
        #expect(map == [.worker: .workerQuestion, .reviewer: .reviewerApproved])
    }

    @Test("An unknown pass is refused")
    func unknownPassIsRefused() {
        #expect(throws: (any Error).self) {
            try ResultFixtureOption.parse(["mystery=worker-question"])
        }
    }

    @Test("An unknown fixture is refused")
    func unknownFixtureIsRefused() {
        #expect(throws: (any Error).self) {
            try ResultFixtureOption.parse(["worker=worker-mystery"])
        }
    }

    @Test("A fixture whose declared pass differs from the named pass is refused")
    func mismatchedPassFixtureIsRefused() {
        #expect(throws: (any Error).self) {
            try ResultFixtureOption.parse(["worker=reviewer-approved"])
        }
    }

    @Test("The same pass named twice is refused")
    func samePassTwiceIsRefused() {
        #expect(throws: (any Error).self) {
            try ResultFixtureOption.parse(["worker=worker-question", "worker=worker-failed"])
        }
    }

    @Test("A malformed entry without `=` is refused")
    func malformedEntryIsRefused() {
        #expect(throws: (any Error).self) {
            try ResultFixtureOption.parse(["worker-question"])
        }
    }

    @Test("An empty array parses to an empty map")
    func emptyArrayParsesToEmptyMap() throws {
        #expect(try ResultFixtureOption.parse([]).isEmpty)
    }

    @Test("A Card-scoped entry parses into byCard, keyed by (issue id, pass)")
    func cardScopedEntryParsesIntoByCard() throws {
        let script = try ResultFixtureOption.parse(["worker@BACK-1=worker-question"])
        #expect(script.byCard == [CardPass(issueID: "BACK-1", pass: .worker): .workerQuestion])
        #expect(script.byPass.isEmpty)
    }

    @Test("A by-pass entry and a Card-scoped entry for the same pass coexist")
    func byPassAndByCardCoexist() throws {
        let script = try ResultFixtureOption.parse(["worker=worker-completed", "worker@BACK-1=worker-question"])
        #expect(script.byPass == [.worker: .workerCompleted])
        #expect(script.byCard == [CardPass(issueID: "BACK-1", pass: .worker): .workerQuestion])
    }

    @Test("The same (pass, Card issue id) named twice is refused")
    func samePassAndCardTwiceIsRefused() {
        #expect(throws: (any Error).self) {
            try ResultFixtureOption.parse(["worker@BACK-1=worker-question", "worker@BACK-1=worker-failed"])
        }
    }

    @Test("An empty Card issue id is refused", arguments: ["worker@=worker-question"])
    func emptyCardIssueIDIsRefused(_ entry: String) {
        #expect(throws: (any Error).self) {
            try ResultFixtureOption.parse([entry])
        }
    }

    @Test("A whitespace-bearing Card issue id is refused")
    func whitespaceBearingCardIssueIDIsRefused() {
        #expect(throws: (any Error).self) {
            try ResultFixtureOption.parse(["worker@BACK 1=worker-question"])
        }
    }

    @Test("A Card-scoped fixture whose declared pass differs from the named pass is refused")
    func mismatchedPassCardScopedFixtureIsRefused() {
        #expect(throws: (any Error).self) {
            try ResultFixtureOption.parse(["worker@BACK-1=reviewer-approved"])
        }
    }
}

@Suite("--result-fixture on the Act commands")
struct ActCommandResultFixtureTests {
    @Test("A valid --result-fixture alongside --rehearsal parses into resultFixtures")
    func validResultFixtureAlongsideRehearsalParses() throws {
        let command = try AuthorCommand.parse([
            "--project", "alpha", "--rehearsal", "--result-fixture", "worker=worker-question"
        ])
        #expect(command.resultFixtures == [.worker: .workerQuestion])
    }

    @Test("--result-fixture without --rehearsal is refused on every Act command")
    func resultFixtureWithoutRehearsalIsRefused() {
        #expect(throws: (any Error).self) {
            try AuthorCommand.parse(["--project", "alpha", "--result-fixture", "worker=worker-question"])
        }
        #expect(throws: (any Error).self) {
            try BuildCommand.parse(["--project", "alpha", "--result-fixture", "worker=worker-question"])
        }
        #expect(throws: (any Error).self) {
            try LandCommand.parse(["--project", "alpha", "--result-fixture", "worker=worker-question"])
        }
    }

    @Test("An unknown pass is refused at parse time")
    func unknownPassRefusedAtParseTime() {
        #expect(throws: (any Error).self) {
            try BuildCommand.parse(["--project", "alpha", "--rehearsal", "--result-fixture", "mystery=worker-question"])
        }
    }

    @Test("Multiple --result-fixture options for distinct passes all parse")
    func multipleDistinctPassesParse() throws {
        let command = try LandCommand.parse([
            "--project", "alpha", "--rehearsal",
            "--result-fixture", "worker=worker-question",
            "--result-fixture", "verifier=verifier-failed"
        ])
        #expect(command.resultFixtures == [.worker: .workerQuestion, .verifier: .verifierFailed])
    }

    @Test("A Card-scoped --result-fixture alongside --rehearsal parses on an Act command")
    func cardScopedResultFixtureAlongsideRehearsalParses() throws {
        let command = try BuildCommand.parse([
            "--project", "alpha", "--rehearsal", "--result-fixture", "worker@BACK-1=worker-question"
        ])
        #expect(command.resultFixtures.byCard == [CardPass(issueID: "BACK-1", pass: .worker): .workerQuestion])
    }
}

@Suite("--night on the Act commands (P15.3)")
struct ActCommandNightTests {
    @Test("--night alongside --rehearsal parses into night")
    func nightAlongsideRehearsalParses() throws {
        let command = try AuthorCommand.parse(["--project", "alpha", "--rehearsal", "--night", "2026-01-10"])
        #expect(command.night == NightStart(rawValue: "2026-01-10"))
    }

    @Test("--night without --rehearsal is refused on every Act command")
    func nightWithoutRehearsalIsRefused() {
        #expect(throws: (any Error).self) {
            try AuthorCommand.parse(["--project", "alpha", "--night", "2026-01-10"])
        }
        #expect(throws: (any Error).self) {
            try BuildCommand.parse(["--project", "alpha", "--night", "2026-01-10"])
        }
        #expect(throws: (any Error).self) {
            try LandCommand.parse(["--project", "alpha", "--night", "2026-01-10"])
        }
    }

    @Test("A malformed --night date is refused at parse time", arguments: ["not-a-date", "2026-13-40", "2026/01/10"])
    func malformedNightIsRefused(_ raw: String) {
        #expect(throws: (any Error).self) {
            try AuthorCommand.parse(["--project", "alpha", "--rehearsal", "--night", raw])
        }
    }

    @Test("Without --night, night is nil")
    func withoutNightIsNil() throws {
        let command = try BuildCommand.parse(["--project", "alpha", "--rehearsal"])
        #expect(command.night == nil)
    }
}
