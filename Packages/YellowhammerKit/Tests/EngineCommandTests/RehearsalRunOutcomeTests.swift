import Domain
import Engine
import Testing

// P7.2: process lifecycle — rehearsal never spawns a CLI

@Test("Every valid rehearsal fixture's outcome is .completed for its declared pass")
func validFixturesOutcomeIsCompleted() {
    let validFixtures: [RehearsalResultFixture] = [
        .architectPlanned,
        .architectFailed,
        .workerCompleted,
        .workerQuestion,
        .workerFailed,
        .reviewerApproved,
        .reviewerChangesRequested
    ]

    for fixture in validFixtures {
        guard case .completed(let result) = fixture.outcome() else {
            Issue.record("expected \(fixture) outcome to be .completed, got \(fixture.outcome())")
            continue
        }
        #expect(result.pass == fixture.pass)
    }
}

@Test("The empty worker fixture is Crashed-Unknown, exactly as a live SIGTERM-failure run would be")
func workerEmptyFixtureIsCrashedUnknown() {
    #expect(RehearsalResultFixture.workerEmpty.outcome() == .crashedUnknown(.resultFile(.empty)))
}

@Test("The malformed worker fixture is Crashed-Unknown, exactly as a live truncated-JSON run would be")
func workerMalformedFixtureIsCrashedUnknown() {
    guard case .crashedUnknown(.resultFile(.malformedJSON)) = RehearsalResultFixture.workerMalformed.outcome() else {
        Issue.record("expected .crashedUnknown(.resultFile(.malformedJSON(_)))")
        return
    }
}
