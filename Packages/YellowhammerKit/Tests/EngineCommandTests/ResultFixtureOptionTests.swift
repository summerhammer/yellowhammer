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
}
