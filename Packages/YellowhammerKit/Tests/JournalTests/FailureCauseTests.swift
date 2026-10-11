import Domain
import Foundation
@testable import Journal
import Testing

// loop-state/record-failure-cause-recurrence (roadmap P8.8): what a failure is reduced to.

@Suite("Failure cause")
struct FailureCauseTests {
    @Test("Only a failure has a cause")
    func successAndQuestionHaveNone() {
        #expect(FailureCause(ending: .success) == nil)
        #expect(FailureCause(ending: .question) == nil)
    }

    @Test("The hash is taken over structural facts: model-authored prose and the Round count never enter it")
    func proseNeverEntersTheHash() throws {
        let one = try #require(FailureCause(ending: .hardFailure(.reported(reason: "the types do not line up"))))
        let other = try #require(FailureCause(ending: .hardFailure(.reported(reason: "cannot make the types agree"))))
        #expect(one.hash == other.hash)
        #expect(one.canonical == "hard failure|reported")

        let twoRounds = try #require(FailureCause(ending: .roundsExhausted(rounds: 2), lens: .review))
        let threeRounds = try #require(FailureCause(ending: .roundsExhausted(rounds: 3), lens: .review))
        #expect(twoRounds.hash == threeRounds.hash)
    }

    @Test("Different structural facts are different causes")
    func structuralFactsSeparateCauses() throws {
        let exitTwo = try #require(FailureCause(ending: .hardFailure(.exitStatus(2))))
        let exitThree = try #require(FailureCause(ending: .hardFailure(.exitStatus(3))))
        let byReview = try #require(FailureCause(ending: .roundsExhausted(rounds: 2), lens: .review))
        let byCheck = try #require(FailureCause(ending: .roundsExhausted(rounds: 2), lens: .check))
        let signaled = try #require(FailureCause(ending: .crashedUnknown(.signaled(9))))
        #expect(Set([exitTwo, exitThree, byReview, byCheck, signaled].map(\.hash)).count == 5)
        #expect(exitTwo.summary == "hard failure (exit status 2)")
    }

    @Test("A contract violation hashes by its structural kind, never the model's prose")
    func contractViolationKindIsStructural() throws {
        let one = try #require(FailureCause(
            ending: .hardFailure(.contractViolation(.invalid(field: "commit", reason: "got `abc` which is short")))
        ))
        let other = try #require(FailureCause(
            ending: .hardFailure(.contractViolation(.invalid(field: "commit", reason: "got `zzz`, not hex")))
        ))
        #expect(one.hash == other.hash)
        #expect(one.canonical == "hard failure|contract violation: invalid commit")

        let noCommit = try #require(FailureCause(ending: .hardFailure(.contractViolation(.completedWithoutCommit))))
        #expect(noCommit.canonical == "hard failure|contract violation: completed without a commit")
        #expect(noCommit.hash != one.hash)
    }

    @Test("A contract violation and a Crashed-Unknown result-file cause are different causes")
    func contractViolationDiffersFromResultFileCrash() throws {
        let violation = try #require(FailureCause(ending: .hardFailure(.contractViolation(.completedWithoutCommit))))
        let crash = try #require(FailureCause(ending: .crashedUnknown(.resultFile(.empty))))
        #expect(violation.hash != crash.hash)
    }

    @Test("The hash is lowercase hex SHA-256 of the canonical form")
    func hashIsStable() throws {
        let cause = try #require(FailureCause(ending: .hardFailure(.exitStatus(2))))
        #expect(cause.hash.count == 64)
        #expect(cause.hash == cause.hash.lowercased())
        #expect(cause.hash == FailureCause(ending: .hardFailure(.exitStatus(2)))?.hash)
    }
}
