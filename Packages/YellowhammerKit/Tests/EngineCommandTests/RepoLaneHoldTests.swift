import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// spec ruling OQ182 (2026-10-22), items 2 and 5: `RepoLane.sequencePredecessors(of:)` and
// `RepoLane.holder(of:currentCard:)`, the shared same-repository hold predicate. Every newly authored
// Card of a lane belongs to one sequence; an adopted Card belongs to the sequence of the Cards adopted
// from the same previous Feature, and these two kinds of sequence never hold one another.

private let repoLaneHoldEpoch = Date(timeIntervalSince1970: 1_800_000_000)

/// A minimal fixture `CardRecord`, every column defaulted so a test only names what it's checking.
private func fixtureCard(
    id: Int64, authoredOrder: Int, state: CardState = .todo, removedFromBoard: CardRemoval? = nil
) -> CardRecord {
    CardRecord(
        id: id, cycleID: 1, issueID: "CARD-\(id)", title: nil, repository: "backend", kind: "card",
        authoredOrder: authoredOrder, state: state, waitingReason: nil, blockReason: nil, shelvedFromState: nil,
        budgetEpoch: 0, createdAt: repoLaneHoldEpoch, stateVersion: 0, boardStateVersion: nil, unansweredNights: 0,
        unansweredLastCountedNightID: nil, failedAdoptions: 0, divergenceStandingNightID: nil,
        removedFromBoard: removedFromBoard
    )
}

@Suite("RepoLane's same-repository hold (OQ182)")
struct RepoLaneHoldTests {
    @Test("Every not-Done state holds: Blocked, Waiting on You, In Progress, Shelved and Todo")
    func everyNotDoneStateHolds() throws {
        for state: CardState in [.blocked, .waitingOnYou, .inProgress, .shelved, .todo] {
            let first = fixtureCard(id: 1, authoredOrder: 1, state: state)
            let second = fixtureCard(id: 2, authoredOrder: 2)
            let lane = RepoLane(repository: "backend", cards: [first, second])

            let holder = lane.holder(of: second) { $0 }
            #expect(holder?.id == first.id, "state \(state) should hold its sequence successor")
        }
    }

    @Test("A Done predecessor does not hold")
    func doneDoesNotHold() throws {
        let first = fixtureCard(id: 1, authoredOrder: 1, state: .done)
        let second = fixtureCard(id: 2, authoredOrder: 2)
        let lane = RepoLane(repository: "backend", cards: [first, second])

        #expect(lane.holder(of: second) { $0 } == nil)
    }

    @Test("A predecessor removed from the board holds, whatever state it stood in when removed (OQ142)")
    func removedFromBoardHolds() throws {
        let first = fixtureCard(id: 1, authoredOrder: 1, state: .done, removedFromBoard: .archived)
        let second = fixtureCard(id: 2, authoredOrder: 2)
        let lane = RepoLane(repository: "backend", cards: [first, second])

        #expect(lane.holder(of: second) { $0 }?.id == first.id)
    }

    @Test("An adopted Card never holds, and is never held by, a newly authored Card in the same lane")
    func adoptedAndNewlyAuthoredSequencesDoNotHoldEachOther() throws {
        // Card 1 is adopted; Cards 2 and 3 are newly authored.
        let adopted = fixtureCard(id: 1, authoredOrder: 1, state: .blocked)
        let newlyAuthoredFirst = fixtureCard(id: 2, authoredOrder: 2, state: .blocked)
        let newlyAuthoredSecond = fixtureCard(id: 3, authoredOrder: 3)
        let lane = RepoLane(
            repository: "backend", cards: [adopted, newlyAuthoredFirst, newlyAuthoredSecond],
            adoptedFrom: [adopted.id: "FEAT-OLD"]
        )

        // The newly authored Card's hold comes from the other newly authored Card, never the adopted one.
        #expect(lane.holder(of: newlyAuthoredSecond) { $0 }?.id == newlyAuthoredFirst.id)
        // The adopted Card has no sequence predecessor of its own, so nothing holds it from this lane.
        #expect(lane.holder(of: adopted) { $0 } == nil)
    }

    @Test("Cards adopted from two different previous Features do not hold each other")
    func differentAdoptionOriginsDoNotHoldEachOther() throws {
        let fromFeatureA = fixtureCard(id: 1, authoredOrder: 1, state: .blocked)
        let fromFeatureB = fixtureCard(id: 2, authoredOrder: 2)
        let lane = RepoLane(
            repository: "backend", cards: [fromFeatureA, fromFeatureB],
            adoptedFrom: [fromFeatureA.id: "FEAT-A", fromFeatureB.id: "FEAT-B"]
        )

        #expect(lane.holder(of: fromFeatureB) { $0 } == nil)
    }

    @Test("Cards adopted from the same previous Feature keep their old authored order as one sequence")
    func sameAdoptionOriginSharesOneSequence() throws {
        let first = fixtureCard(id: 1, authoredOrder: 1, state: .blocked)
        let second = fixtureCard(id: 2, authoredOrder: 2)
        let lane = RepoLane(
            repository: "backend", cards: [first, second], adoptedFrom: [first.id: "FEAT-OLD", second.id: "FEAT-OLD"]
        )

        #expect(lane.holder(of: second) { $0 }?.id == first.id)
    }

    @Test("holder(of:currentCard:) re-reads current state rather than trusting the lane's own snapshot")
    func holderReadsCurrentStateThroughTheClosure() throws {
        // The lane's own snapshot says Blocked (stale); the closure reports Done (current).
        let staleFirst = fixtureCard(id: 1, authoredOrder: 1, state: .blocked)
        let currentFirst = fixtureCard(id: 1, authoredOrder: 1, state: .done)
        let second = fixtureCard(id: 2, authoredOrder: 2)
        let lane = RepoLane(repository: "backend", cards: [staleFirst, second])

        let holder = lane.holder(of: second) { card in card.id == staleFirst.id ? currentFirst : card }
        #expect(holder == nil)
    }

    @Test("sequencePredecessors returns only the earlier Cards of the same sequence, in authored order")
    func sequencePredecessorsIsScopedAndOrdered() throws {
        let adopted = fixtureCard(id: 1, authoredOrder: 1)
        let newlyAuthoredFirst = fixtureCard(id: 2, authoredOrder: 2)
        let newlyAuthoredSecond = fixtureCard(id: 3, authoredOrder: 3)
        let newlyAuthoredThird = fixtureCard(id: 4, authoredOrder: 4)
        let lane = RepoLane(
            repository: "backend", cards: [adopted, newlyAuthoredFirst, newlyAuthoredSecond, newlyAuthoredThird],
            adoptedFrom: [adopted.id: "FEAT-OLD"]
        )

        let predecessors = lane.sequencePredecessors(of: newlyAuthoredThird).map(\.id)
        #expect(predecessors == [newlyAuthoredFirst.id, newlyAuthoredSecond.id])
        #expect(lane.sequencePredecessors(of: newlyAuthoredFirst).isEmpty)
    }
}
